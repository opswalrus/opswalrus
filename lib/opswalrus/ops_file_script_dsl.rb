require 'shellwords'
require 'stringio'
require 'random/formatter'

require 'sshkit'
require 'sshkit/dsl'

require_relative 'host'
require_relative 'sshkit_ext'
require_relative 'walrus_lang'

# this file contains all of the logic associated with the invocation of the dynamically defined OpsFileScript#_invoke method

module OpsWalrus

  module Invocation
    class Result
      attr_accessor :value
      attr_accessor :exit_status
      def initialize(value, exit_status = 0)
        @value = value
        @exit_status = exit_status
      end
      def success?
        !failure?
      end
      def failure?
        !success?
      end
    end
    class Success < Result
      def initialize(value)
        super(value, 0)
      end
      def success?
        true
      end
    end
    class Error < Result
      def initialize(value, exit_status = 1)
        super(value, exit_status == 0 ? 1 : exit_status)
      end
      def failure?
        true
      end
    end
  end


  # BootstrapLinuxHostShellScript = <<~SCRIPT
  #   #!/usr/bin/env bash
  #   ...
  # SCRIPT

  module OpsFileScriptDSL
    def ssh_noprep(*args, **kwargs, &block)
      runtime_env = @runtime_env

      hosts = inventory(*args, **kwargs).map {|host| host_proxy_class.new(runtime_env, host) }
      sshkit_hosts = hosts.map(&:sshkit_host)
      sshkit_host_to_ops_host_map = sshkit_hosts.zip(hosts).to_h
      local_host = self
      # on sshkit_hosts do |sshkit_host|
      SSHKit::Coordinator.new(sshkit_hosts).each(in: kwargs[:in] || :parallel) do |sshkit_host|
        # in this context, self is an instance of one of the subclasses of SSHKit::Backend::Abstract, e.g. SSHKit::Backend::Netssh
        host = sshkit_host_to_ops_host_map[sshkit_host]

        begin
          host.set_runtime_env(runtime_env)
          host.set_ssh_session_connection(self)  # self is an instance of one of the subclasses of SSHKit::Backend::Abstract, e.g. SSHKit::Backend::Netssh

          # we run the block in the context of the host proxy object, s.t. `self` within the block evaluates to the host proxy object
          retval = host.instance_exec(local_host, &block)    # local_host is passed as the argument to the block

          retval
        rescue SSHKit::Command::Failed => e
          App.instance.error "[!] Command failed:"
          App.instance.error e.message
        rescue Net::SSH::ConnectionTimeout
          App.instance.error "[!] The host '#{host}' not alive!"
        rescue Net::SSH::Timeout
          App.instance.error "[!] The host '#{host}' disconnected/timeouted unexpectedly!"
        rescue Errno::ECONNREFUSED
          App.instance.error "[!] Incorrect port #{port} for #{host}"
        rescue Net::SSH::HostKeyMismatch => e
          App.instance.error "[!] The host fingerprint does not match the last observed fingerprint for #{host}"
          App.instance.error e.message
          App.instance.error "You might try `ssh-keygen -f ~/.ssh/known_hosts -R \"#{host}\"`"
        rescue Net::SSH::AuthenticationFailed
          App.instance.error "Wrong Password: #{host} | #{user}:#{password}"
        rescue Net::SSH::Authentication::DisallowedMethod
          App.instance.error "[!] The host '#{host}' doesn't accept password authentication method."
        rescue Errno::EHOSTUNREACH => e
          App.instance.error "[!] The host '#{host}' is unreachable"
        rescue => e
          App.instance.error e.class
          App.instance.error e.message
          App.instance.error e.backtrace.join("\n")
        ensure
          host.clear_ssh_session
        end
      end
    end

    def ssh(*args, **kwargs, &block)
      runtime_env = @runtime_env

      hosts = inventory(*args, **kwargs).map {|host| host_proxy_class.new(runtime_env, host) }
      sshkit_hosts = hosts.map(&:sshkit_host)
      sshkit_host_to_ops_host_map = sshkit_hosts.zip(hosts).to_h
      ops_file_script = local_host = self
      # bootstrap_shell_script = BootstrapLinuxHostShellScript
      # on sshkit_hosts do |sshkit_host|
      SSHKit::Coordinator.new(sshkit_hosts).each(in: kwargs[:in] || :parallel) do |sshkit_host|
        # in this context, self is an instance of one of the subclasses of SSHKit::Backend::Abstract, e.g. SSHKit::Backend::Netssh
        host = sshkit_host_to_ops_host_map[sshkit_host]

        begin
          host.set_runtime_env(runtime_env)
          host.set_ops_file_script(ops_file_script)
          host.set_ssh_session_connection(self)  # self is an instance of one of the subclasses of SSHKit::Backend::Abstract, e.g. SSHKit::Backend::Netssh

          stdout, stderr, exit_status = host._bootstrap_host(false)
          retval = if exit_status == 0
            host._zip_copy_and_run_ops_bundle(local_host, block)
          else
            puts "Failed to bootstrap #{host}. Unable to run operation."
          end

          retval
        rescue SSHKit::Command::Failed => e
          App.instance.error "[!] Command failed:"
          App.instance.error e.message
        rescue Net::SSH::ConnectionTimeout
          App.instance.error "[!] The host '#{host}' not alive!"
        rescue Net::SSH::Timeout
          App.instance.error "[!] The host '#{host}' disconnected/timeouted unexpectedly!"
        rescue Errno::ECONNREFUSED
          App.instance.error "[!] Incorrect port #{port} for #{host}"
        rescue Net::SSH::HostKeyMismatch => e
          App.instance.error "[!] The host fingerprint does not match the last observed fingerprint for #{host}"
          App.instance.error e.message
          App.instance.error "You might try `ssh-keygen -f ~/.ssh/known_hosts -R \"#{host}\"`"
        rescue Net::SSH::AuthenticationFailed
          App.instance.error "Wrong Password: #{host} | #{user}:#{password}"
        rescue Net::SSH::Authentication::DisallowedMethod
          App.instance.error "[!] The host '#{host}' doesn't accept password authentication method."
        rescue Errno::EHOSTUNREACH => e
          App.instance.error "[!] The host '#{host}' is unreachable"
        rescue => e
          App.instance.error e.class
          App.instance.error e.message
          App.instance.error e.backtrace.join("\n")
        ensure
          host.clear_ssh_session
        end
      end
    end

    def current_dir
      File.dirname(File.realpath(@runtime_ops_file_path)).to_pathname
    end

    def inventory(*args, **kwargs)
      tags = args.map(&:to_s)

      kwargs = kwargs.transform_keys(&:to_s)
      tags.concat(kwargs["tags"]) if kwargs["tags"]

      @runtime_env.app.inventory(tags)
    end

    def exit(exit_status, message = nil)
      if message
        puts message.mustache(1)
      end
      result = if exit_status == 0
        Invocation::Success.new(nil)
      else
        Invocation::Error.new(nil, exit_status)
      end
      throw :exit_now, result
    end

    # currently, import may only be used to import a package that is referenced in the script's package file
    # I may decide to extend this to work with dynamic package references
    #
    # local_package_name is the local package name defined for the package dependency that is attempting to be referenced
    def import(local_package_name)
      local_package_name = local_package_name.to_s
      package_reference = ops_file.package_file&.dependency(local_package_name)
      raise Error, "Unknown package reference: #{local_package_name}" unless package_reference
      import_reference = PackageDependencyReference.new(local_package_name, package_reference)
      namespace_or_ops_file = @runtime_env.resolve_import_reference(ops_file, import_reference)
      raise SymbolResolutionError, "Import reference '#{import_reference.summary}' not in load path for #{ops_file.ops_file_path}" unless namespace_or_ops_file
      invocation_context = LocalImportInvocationContext.new(@runtime_env, namespace_or_ops_file)
      # invocation_context = LocalImportInvocationContext.new(@runtime_env, namespace_or_ops_file)
      # invocation_context._invoke(*args, **kwargs)
    end

    def desc(msg)
      puts Style.green(msg.mustache(1))
    end

    def warn(msg)
      puts Style.yellow(msg.mustache(1))
    end

    def debug(msg)
      puts msg.mustache(1) if App.instance.debug? || App.instance.trace?
    end

    def env(*keys)
      keys = keys.map(&:to_s)
      if keys.empty?
        @runtime_env.env
      else
        @runtime_env.env.dig(*keys)
      end
    end

    # runs the given command
    # returns the stdout from the command
    def sh(desc_or_cmd = nil, cmd = nil, input: nil, &block)
      out, err, status = *shell!(desc_or_cmd, cmd, block, input: input)
      out
    end

    # runs the given command
    # returns true if the exit status was success; false otherwise
    def sh?(desc_or_cmd = nil, cmd = nil, input: nil, &block)
      out, err, status = *shell!(desc_or_cmd, cmd, block, input: input)
      status == 0
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell(desc_or_cmd = nil, cmd = nil, input: nil, &block)
      shell!(desc_or_cmd, cmd, block, input: input)
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell!(desc_or_cmd = nil, cmd = nil, block = nil, input: nil, log_level: nil)
      return ["", "", 0] if !desc_or_cmd && !cmd && !block    # we were told to do nothing; like hitting enter at the bash prompt; we can do nothing successfully

      description = desc_or_cmd if cmd || block
      description = WalrusLang.render(description, block.binding) if description && block
      cmd = block.call if block
      cmd ||= desc_or_cmd

      cmd = if cmd =~ /{{.*}}/
        if block
          WalrusLang.render(cmd, block.binding)
        else
          offset = 3    # 3, because 1 references the stack frame corresponding to the caller of WalrusLang.eval,
                        # 2 references the stack frame corresponding to the caller of shell!,
                        # and 3 references the stack frame corresponding to teh caller of either sh/sh?/shell
          WalrusLang.eval(cmd, offset)
        end
      else
        cmd
      end
      #cmd = Shellwords.escape(cmd)

      report_on(@runtime_env.local_hostname, description, cmd, log_level: log_level) do
        if App.instance.dry_run?
          ["", "", 0]
        else
          sshkit_cmd = @runtime_env.handle_input(input, inherit_existing_mappings: true) do |interaction_handler|
            # puts "self=#{self.class.superclass}"
            # self is an instance of one of the dynamically defined subclasses of OpsFileScript
            App.instance.debug("OpsFileScriptDSL#shell! cmd=#{cmd} with input mappings #{interaction_handler.input_mappings.inspect} given input: #{input.inspect})")
            backend.execute_cmd(cmd, interaction_handler: interaction_handler)
          end
          [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]
        end
      end
    end

    def report_on(hostname, description = nil, cmd, log_level: nil)
      cmd_id = Random.uuid.split('-').first

      output_block = StringIO.open do |io|
        io.print Style.blue(hostname)
        io.print " | #{Style.magenta(description)}" if description
        io.puts
        io.print Style.yellow(cmd_id)
        io.print Style.green.bold(" > ")
        io.puts Style.yellow(cmd)
        io.string
      end
      puts output_block

      t1 = Time.now
      out, err, exit_status = yield
      t2 = Time.now
      seconds = t2 - t1

      output_block = StringIO.open do |io|
        if App.instance.info? || log_level == :info
          io.puts Style.cyan(out)
          io.puts Style.red(err)
        elsif App.instance.debug? || log_level == :debug
          io.puts Style.cyan(out)
          io.puts Style.red(err)
        elsif App.instance.trace? || log_level == :trace
          io.puts Style.cyan(out)
          io.puts Style.red(err)
        end
        io.print Style.yellow(cmd_id)
        io.print Style.blue(" | Finished in #{seconds} seconds with exit status ")
        if exit_status == 0
          io.puts Style.green("#{exit_status} (#{exit_status == 0 ? 'success' : 'failure'})")
        else
          io.puts Style.red("#{exit_status} (#{exit_status == 0 ? 'success' : 'failure'})")
        end
        io.puts Style.green("*" * 80)
        io.string
      end
      puts output_block

      [out, err, exit_status]
    end

  end

end
