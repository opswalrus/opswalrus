require 'json'
require 'set'
require 'shellwords'
require 'socket'
require 'stringio'

# require 'ed25519'
require 'sshkit'
require 'sshkit/dsl'

require_relative 'host'
require_relative 'sshkit_ext'
require_relative 'walrus_lang'

module OpsWalrus
  class ArrayOrHashNavigationProxy
    def initialize(array_or_hash)
      @obj = array_or_hash
    end
    def [](index, *args, **kwargs, &block)
      @obj.method(:[]).call(index, *args, **kwargs, &block)
    end
    def respond_to_missing?(method, *)
      @obj.is_a?(Hash) && @obj.respond_to?(method)
    end
    def method_missing(name, *args, **kwargs, &block)
      case @obj
      when Array
        @obj.method(name).call(*args, **kwargs, &block)
      when Hash
        if @obj.respond_to?(name)
          @obj.method(name).call(*args, **kwargs, &block)
        else
          value = self[name.to_s]
          case value
          when Array, Hash
            ArrayOrHashNavigationProxy.new(value)
          else
            value
          end
        end
      end
    end
  end

  class Params
    # params : Hash
    def initialize(params)
      @params = params
    end

    def [](key)
      key = key.to_s if key.is_a? Symbol
      @params[key]
    end

    def dig(*keys)
      # keys = keys.map {|key| key.is_a?(Integer) ? key : key.to_s }
      @params.dig(*keys)
    end

    def method_missing(name, *args, **kwargs, &block)
      if @params.respond_to?(name)
        @params.method(name).call(*args, **kwargs, &block)
      else
        value = self[name]
        case value
        when Array, Hash
          ArrayOrHashNavigationProxy.new(value)
        else
          value
        end
      end
    end
  end

  class Env
    # env : Hash
    def initialize(env)
      @env = env
    end

    def [](key)
      key = key.to_s if key.is_a? Symbol
      @env[key]
    end

    def dig(*keys)
      keys = keys.map {|key| key.is_a?(Integer) ? key : key.to_s }
      @env.dig(*keys)
    end

    def method_missing(name, *args, **kwargs, &block)
      if @env.respond_to?(name)
        @env.method(name).call(*args, **kwargs, &block)
      else
        value = self[name]
        case value
        when Array, Hash
          ArrayOrHashNavigationProxy.new(value)
        else
          value
        end
      end
    end
  end

  # BootstrapLinuxHostShellScript = <<~SCRIPT
  #   #!/usr/bin/env bash
  #   ...
  # SCRIPT

  module DSL
    def ssh(*args, **kwargs, &block)
      host_proxy_class = @ops_file_script.host_proxy_class
      hosts = inventory(*args, **kwargs).map {|host| host_proxy_class.new(host) }
      sshkit_hosts = hosts.map(&:sshkit_host)
      sshkit_host_to_ops_host_map = sshkit_hosts.zip(hosts).to_h
      runtime_env = @runtime_env
      local_host = self
      # bootstrap_shell_script = BootstrapLinuxHostShellScript
      # on sshkit_hosts do |sshkit_host|
      SSHKit::Coordinator.new(sshkit_hosts).each(in: kwargs[:in] || :parallel) do |sshkit_host|
        host = sshkit_host_to_ops_host_map[sshkit_host]

        # puts "#{host.alias} / #{host}:"

        begin
          # in this context, self is an instance of one of the subclasses of SSHKit::Backend::Abstract, e.g. SSHKit::Backend::Netssh
          host.set_ssh_session_connection(self)

          # copy over bootstrap shell script
          # io = StringIO.new(bootstrap_shell_script)
          io = File.open(__FILE__.to_pathname.dirname.join("bootstrap.sh"))
          upload_success = host.upload(io, "tmpopsbootstrap.sh")
          io.close
          raise Error, "Unable to upload bootstrap shell script to remote host" unless upload_success
          host.execute(:chmod, "755", "tmpopsbootstrap.sh")
          host.execute(:sh, "tmpopsbootstrap.sh")

          # copy over ops bundle zip file
          zip_bundle_path = runtime_env.zip_bundle_path
          upload_success = host.upload(zip_bundle_path, "tmpops.zip")
          raise Error, "Unable to upload ops bundle to remote host" unless upload_success

          stdout, stderr, exit_status = host.run_ops(:bundle, "unzip tmpops.zip", in_bundle_root_dir: false)
          raise Error, "Unable to unzip ops bundle on remote host" unless exit_status == 0
          tmp_bundle_root_dir = stdout.strip
          host.set_ssh_session_tmp_bundle_root_dir(tmp_bundle_root_dir)

          # we run the block in the context of the host, s.t. `self` within the block evaluates to `host`
          retval = host.instance_exec(local_host, &block)    # host is passed as the argument to the block

          puts retval.inspect

          # cleanup
          if tmp_bundle_root_dir =~ /tmp/   # sanity check the temp path before we blow away something we don't intend
            host.execute(:rm, "-rf", "tmpopsbootstrap.sh", "tmpops.zip", tmp_bundle_root_dir)
          else
            host.execute(:rm, "-rf", "tmpopsbootstrap.sh", "tmpops.zip")
          end

          retval
        rescue SSHKit::Command::Failed => e
          puts "[!] Command failed:"
          puts e.message
        rescue Net::SSH::ConnectionTimeout
          puts "[!] The host '#{host}' not alive!"
        rescue Net::SSH::Timeout
          puts "[!] The host '#{host}' disconnected/timeouted unexpectedly!"
        rescue Errno::ECONNREFUSED
          puts "[!] Incorrect port #{port} for #{host}"
        rescue Net::SSH::HostKeyMismatch => e
          puts "[!] The host fingerprint does not match the last observed fingerprint for #{host}"
          puts e.message
          puts "You might try `ssh-keygen -f ~/.ssh/known_hosts -R \"#{host}\"`"
        rescue Net::SSH::AuthenticationFailed
          puts "Wrong Password: #{host} | #{user}:#{password}"
        rescue Net::SSH::Authentication::DisallowedMethod
          puts "[!] The host '#{host}' doesn't accept password authentication method."
        rescue Errno::EHOSTUNREACH => e
          puts "[!] The host '#{host}' is unreachable"
        rescue => e
          puts e.class
          puts e.message
          # puts e.backtrace.join("\n")
        ensure
          host.clear_ssh_session
        end
      end
    end

    def inventory(*args, **kwargs)
      tags = args.map(&:to_s)

      kwargs = kwargs.transform_keys(&:to_s)
      tags.concat(kwargs["tags"]) if kwargs["tags"]

      @runtime_env.app.inventory(tags)
    end

    def exit(exit_status)
      result = if exit_status == 0
        Success.new(nil)
      else
        Error.new(nil, exit_status)
      end
      throw :exit_now, result
    end

    def env(*keys)
      keys = keys.map(&:to_s)
      if keys.empty?
        @env
      else
        @env.dig(*keys)
      end
    end

    # local_package_name is the local package name defined for the package dependency that is attempting to be referenced
    def import(local_package_name)
      local_package_name = local_package_name.to_s
      package_reference = @ops_file_script.ops_file.package_file&.dependency(local_package_name)
      raise Error, "Unknown package reference: #{local_package_name}" unless package_reference
      import_reference = PackageDependencyReference.new(local_package_name, package_reference)
      # puts "import: #{import_reference.inspect}"
      @runtime_env.resolve_import_reference(@ops_file_script.ops_file, import_reference)
    end

    def params(*keys, default: nil)
      keys = keys.map(&:to_s)
      if keys.empty?
        @params
      else
        @params.dig(*keys) || default
      end
    end

    # returns the stdout from the command
    def sh(desc_or_cmd = nil, cmd = nil, stdin: nil, &block)
      out, err, status = *shell!(desc_or_cmd, cmd, block, stdin: stdin)
      out
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell(desc_or_cmd = nil, cmd = nil, stdin: nil, &block)
      shell!(desc_or_cmd, cmd, block, stdin: stdin)
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell!(desc_or_cmd = nil, cmd = nil, block = nil, stdin: nil)
      # description = nil

      return ["", "", 0] if !desc_or_cmd && !cmd && !block    # we were told to do nothing; like hitting enter at the bash prompt; we can do nothing successfully

      description = desc_or_cmd if cmd || block
      cmd = block.call if block
      cmd ||= desc_or_cmd

      # puts "shell! self: #{self.inspect}"

      print "[#{@runtime_env.local_hostname}] "
      print "#{description}: " if description
      puts cmd

      cmd = WalrusLang.render(cmd, block.binding) if block && cmd =~ /{{.*}}/
      return unless cmd && !cmd.strip.empty?

      #cmd = Shellwords.escape(cmd)

      sudo_password = @runtime_env.sudo_password
      sudo_password &&= sudo_password.gsub(/\n+$/,'')     # remove trailing newlines from sudo_password

      # puts "shell: #{cmd}"
      # puts "shell: #{cmd.inspect}"
      # puts "sudo_password: #{sudo_password}"

      # sshkit_cmd = SSHKit::Backend::LocalNonBlocking.new {
      # sshkit_cmd = SSHKit::Backend::LocalPty.new {
      sshkit_cmd = backend.execute_cmd(cmd, interaction_handler: SudoPasswordMapper.new(sudo_password).interaction_handler, verbosity: :info)
        # execute_cmd(cmd, interaction_handler: SudoPromptInteractionHandler.new, verbosity: :info)
      # }.run

      [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]
    end

    # def init_brew
    #   execute('eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"')
    # end

  end

  class OpsFileScript
    attr_accessor :ops_file

    def initialize(ops_file, ruby_script)
      @ops_file = ops_file
      @ruby_script = ruby_script
      @invocation_class = define_invocation_class
      @host_proxy_class = define_host_proxy_class
    end

    def define_invocation_class
      klass = Class.new(Invocation)

      methods_defined = Set.new

      # define methods for every import in the script
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            # puts "0" * 80
            # puts "@runtime_env.resolve_import_reference(@ops_file_script.ops_file, #{import_reference.inspect})"
            # puts @ops_file_script.ops_file.ops_file_path
            # puts symbol_name
            namespace_or_ops_file = @runtime_env.resolve_import_reference(@ops_file_script.ops_file, import_reference)
            # puts namespace_or_ops_file.inspect
            # puts "0" * 80
            case namespace_or_ops_file
            when Namespace
              namespace_or_ops_file
            when OpsFile
              params_hash = namespace_or_ops_file.build_params_hash(*args, **kwargs)
              namespace_or_ops_file.invoke(@runtime_env, params_hash)
            end
          end
          methods_defined << symbol_name
        end
      end

      # define methods for every Namespace or OpsFile within the namespace that the OpsFile resides within
      sibling_symbol_table = Set.new
      sibling_symbol_table |= ops_file.dirname.glob("*.ops").map {|ops_file_path| ops_file_path.basename(".ops").to_s }   # OpsFiles
      sibling_symbol_table |= ops_file.dirname.glob("*").select(&:directory?).map {|dir_path| dir_path.basename.to_s }    # Namespaces
      sibling_symbol_table.each do |symbol_name|
        unless methods_defined.include? symbol_name
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            # puts "0" * 80
            # puts "@runtime_env.resolve_symbol(@ops_file_script.ops_file, #{symbol_name})"
            # puts @ops_file_script.ops_file.ops_file_path
            # puts symbol_name
            namespace_or_ops_file = @runtime_env.resolve_sibling_symbol(@ops_file_script.ops_file, symbol_name)
            # puts namespace_or_ops_file.inspect
            # puts "0" * 80
            case namespace_or_ops_file
            when Namespace
              namespace_or_ops_file
            when OpsFile
              params_hash = namespace_or_ops_file.build_params_hash(*args, **kwargs)
              namespace_or_ops_file.invoke(@runtime_env, params_hash)
            end
          end
          methods_defined << symbol_name
        end
      end

      klass
    end

    def define_host_proxy_class
      klass = Class.new(HostProxy)

      methods_defined = Set.new

      # define methods for every import in the script
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          # puts "1. defining: #{symbol_name}(...)"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            invocation_builder = case import_reference
            # we know we're dealing with a package dependency reference, so we want to run an ops file contained within the bundle directory,
            # therefore, we want to reference the specified ops file with respect to the bundle dir
            when PackageDependencyReference
              HostProxyOpsFileInvocationBuilder.new(self, true)

            # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
            # the specified ops file with respect to the root directory, and not with respect to the bundle dir
            when DirectoryReference, OpsFileReference
              HostProxyOpsFileInvocationBuilder.new(self, false)
            end

            invocation_builder.send(symbol_name, *args, **kwargs, &block)
          end
          methods_defined << symbol_name
        end
      end

      # define methods for every Namespace or OpsFile within the namespace that the OpsFile resides within
      sibling_symbol_table = Set.new
      sibling_symbol_table |= ops_file.dirname.glob("*.ops").map {|ops_file_path| ops_file_path.basename(".ops").to_s }   # OpsFiles
      sibling_symbol_table |= ops_file.dirname.glob("*").select(&:directory?).map {|dir_path| dir_path.basename.to_s }    # Namespaces
      sibling_symbol_table.each do |symbol_name|
        unless methods_defined.include? symbol_name
          # puts "2. defining: #{symbol_name}(...)"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            invocation_builder = HostProxyOpsFileInvocationBuilder.new(self, false)
            invocation_builder.invoke(symbol_name, *args, **kwargs, &block)
          end
          methods_defined << symbol_name
        end
      end

      klass
    end

    def host_proxy_class
      @host_proxy_class
    end

    def script
      @ruby_script
    end

    def invoke(runtime_env, params_hash)
      # Invocation.new(self, runtime_env, params_hash).evaluate
      # puts "INVOKE" * 10
      # puts runtime_env.inspect
      @invocation_class.new(self, runtime_env, params_hash).evaluate
    end

    def to_s
      @ruby_script
    end
  end

  # An Invocation object represents a stack frame, and the params_hash represents the
  # arguments that the caller has supplied for that stack frame to reference
  class Invocation
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


    include DSL

    def initialize(ops_file_script, runtime_env, params_hash)
      @ops_file_script = ops_file_script
      @runtime_env = runtime_env
      @params = Params.new(params_hash)
    end

    def backend
      @runtime_env.pty
    end

    def debug?
      @runtime_env.debug?
    end

    def verbose?
      @runtime_env.verbose?
    end

    def evaluate
      # catch(:exit_now) do
        eval(@ops_file_script.script, nil, @ops_file_script.ops_file.ops_file_path.to_s, @ops_file_script.ops_file.script_line_offset)
      # end
    end

    # def evaluate
    #   ruby_script_return = begin
    #     catch(:exit_now) do
    #       eval(@ops_file_script.script)
    #     end
    #   rescue => e
    #     $stderr.puts "Error: Ops script crashed."
    #     $stderr.puts e.message
    #     $stderr.puts e.backtrace.join("\n")
    #     Error.new(e)
    #   end

    #   if ruby_script_return.is_a? Result
    #     ruby_script_return
    #   else
    #     Success.new(ruby_script_return)
    #   end
    # end

    # def method_missing(name, *args, **kwargs, &block)
    #   puts "1" * 80
    #   import_reference = @ops_file_script.ops_file.resolve_import(name)
    #   if import_reference
    #     puts "2" * 80
    #     resolved_value = @runtime_env.resolve_import_reference(@ops_file_script.ops_file, import_reference)
    #     return resolved_value if resolved_value
    #   end

    #   puts "3" * 80
    #   case namespace_or_ops_file = @runtime_env.resolve_symbol(@ops_file_script.ops_file, name.to_s)
    #   when Namespace
    #     puts "4" * 80
    #     namespace_or_ops_file
    #   when OpsFile
    #     puts "5" * 80
    #     namespace_or_ops_file.invoke(@runtime_env, *args, **kwargs, &block)
    #   else
    #     raise NoMethodError, "No method named '#{name}'"
    #   end
    # end
  end

end
