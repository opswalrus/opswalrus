require "set"
require "sshkit"
require "stringio"
require "tempfile"

require_relative "interaction_handlers"
require_relative "invocation"

module OpsWalrus

  OPS_GEM="$HOME/.local/share/mise/shims/gem"
  OPS_CMD="$HOME/.local/share/mise/shims/ops"

  # the subclasses of HostProxy will define methods that handle method dispatch via HostProxyOpsFileInvocationBuilder objects
  class HostProxy

    def self.define_host_proxy_class(ops_file)
      klass = Class.new(HostProxy)

      methods_defined = Set.new

      # define methods for every import in the script
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.trace "resolving local symbol table entry: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_import_reference(ops_file, import_reference)
            App.instance.trace "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = case import_reference
            # we know we're dealing with a package dependency reference, so we want to run an ops file contained within the bundle directory,
            # therefore, we want to reference the specified ops file with respect to the bundle dir
            when PackageDependencyReference, DynamicPackageImportReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, true, ops_prompt_for_sudo_password: !!ssh_password)

            # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
            # the specified ops file with respect to the root directory, and not with respect to the bundle dir
            when DirectoryReference, OpsFileReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false, ops_prompt_for_sudo_password: !!ssh_password)
            end

            invocation_context._invoke(*args, **kwargs)

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
            App.instance.trace "resolving implicit import: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_sibling_symbol(ops_file, symbol_name)
            App.instance.trace "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false, ops_prompt_for_sudo_password: !!ssh_password)
            invocation_context._invoke(*args, **kwargs)
          end
          methods_defined << symbol_name
        end
      end

      klass
    end


    attr_accessor :_host

    def initialize(runtime_env, host)
      @_host = host
      @runtime_env = runtime_env
    end

    # the subclasses of this class will define methods that handle method dispatch via RemoteImportInvocationContext objects

    def to_s
      @_host.to_s
    end

    def _invoke_remote(ops_file, *args, **kwargs)
      App.instance.debug "Remove invoke #{ops_file.relative_path_to_app_pwd} on host `#{to_s}` with args:\n  #{args.inspect}\nkwargs:\n  #{kwargs.inspect}"

      RemoteInvocation.new(self, ops_file, ops_prompt_for_sudo_password: !!ssh_password).invoke(*args, **kwargs)
    end

    # returns [stdout, stderr, exit_status]
    def _bootstrap_host(print_report = true)
      # copy over bootstrap shell script
      # io = StringIO.new(bootstrap_shell_script)
      io = File.open(__FILE__.to_pathname.dirname.join("bootstrap.sh"))
      upload_success = @_host.upload(io, "tmpopsbootstrap.sh")
      io.close
      raise Error, "Unable to upload bootstrap shell script to remote host #{to_s} (alias=#{self.alias})" unless upload_success
      @_host.execute(:chmod, "755", "tmpopsbootstrap.sh")
      sshkit_cmd = @_host.execute_cmd(:sh, "tmpopsbootstrap.sh")

      stdout, stderr, exit_status = [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]

      if print_report && App.instance.info?
        if exit_status == 0
          report = "Bootstrap success - #{to_s} (alias=#{self.alias})"
          stdout_report = stdout.lines.last(3).map {|line| "        #{line}" }.join()
          report << "\n    stdout:\n#{stdout_report}" unless stdout_report.empty?
          puts report
        else
          stdout_report = stdout.lines.last(3).map {|line| "        #{line}" }.join()
          stderr_report = stderr.lines.last(3).map {|line| "        #{line}" }.join()
          report = "Bootstrap failure - #{to_s} (alias=#{self.alias})"
          report << "\n    stdout:\n#{stdout_report}" unless stdout_report.empty?
          report << "\n    stderr:\n#{stderr_report}" unless stderr_report.empty?
          puts report
        end
      end

      [stdout, stderr, exit_status]
    ensure
      @_host.execute(:rm, "-f", "tmpopsbootstrap.sh") rescue nil
    end

    def _zip_copy_and_run_ops_bundle(local_host, block)
      @_host._initialize_session

      # we run the block in the context of the host proxy object, s.t. `self` within the block evaluates to the host proxy object (i.e. self)
      retval = instance_exec(local_host, &block)    # local_host is passed as the argument to the block

      @_host._cleanup_session

      retval
    end

    def method_missing(name, ...)
      @_host.send(name, ...)
    end
  end


  module HostDSL
    # delay: integer?     # default: 1 - 1 second delay before reboot
    # sync: boolean?      # default: true - wait for the remote host to become available again before returning success/failure
    # timeout: integer?   # default: 300 - 300 seconds (5 minutes)
    def reboot(delay: 1, sync: true, timeout: 300)
      delay = 1 if delay < 1

      desc "Rebooting #{to_s} (alias=#{self.alias})"
      reboot_success = sh? 'sudo /bin/sh -c "(sleep {{ delay }} && reboot) &"'.mustache
      puts reboot_success

      reconnect_time = reconnect(delay, timeout) if sync
      reconnect_success = !!reconnect_time

      {
        success: reboot_success && (sync == reconnect_success),
        rebooted: reboot_success,
        reconnected: reconnect_success,
        reboot_duration: reconnect_time
      }
    end

    def autoretry(delay: 5, timeout: 300, limit: 3, &block)
      attempts ||= 0
      attempts += 1
      block.call
    rescue RetriableRemoteInvocationError => e
      if attempts <= limit
        reconnected = reconnect(delay, timeout)
        retry if reconnected
      end
    end

    # returns an integer number of seconds if reconnected; nil otherwise
    def reconnect(delay = 1, timeout = 300)
      delay = 1 if delay < 1

      desc "Waiting for #{to_s} (alias=#{self.alias}) to become available. Reconnecting."
      initial_reconnect_delay = delay + 10
      sleep initial_reconnect_delay

      reconnected = false
      give_up = false
      t1 = Time.now
      until reconnected || give_up
        begin
          reconnected = sh?('true')
          # while trying to reconnect, we expect the following exceptions:
          # 1. Net::SSH::Disconnect < Net::SSH::Exception with message: "connection closed by remote host"
          # 2. Errno::ECONNRESET < SystemCallError with message: "Connection reset by peer"
          # 3. Errno::ECONNREFUSED < SystemCallError with message: "Connection refused - connect(2) for 192.168.56.10:22"
        rescue Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED => e
          # noop; we expect these while we're trying to reconnect
        rescue => e
          puts "#{e.class} < #{e.class.superclass}"
          puts e.message
          puts e.backtrace.take(5).join("\n")
        end

        wait_time_elapsed_in_seconds = Time.now - t1
        give_up = wait_time_elapsed_in_seconds > timeout
        sleep 5
      end

      if reconnected
        initial_reconnect_delay + (Time.now - t1)

        # initialize session again
        _initialize_session
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
    def shell!(desc_or_cmd = nil, cmd = nil, block = nil, input: nil, ops_prompt_for_sudo_password: false)
      # description = nil

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
                        # and 3 references the stack frame corresponding to the caller of either sh/sh?/shell
          WalrusLang.eval(cmd, offset)
        end
      else
        cmd
      end
      # cmd = WalrusLang.render(cmd, block.binding) if block && cmd =~ /{{.*}}/

      #cmd = Shellwords.escape(cmd)

      cmd_id = Random.uuid.split('-').first
      output_block = StringIO.open do |io|
        if App.instance.info?   # this is true if log_level is trace, debug, info
          io.print Style.blue(host)
          io.print " (#{Style.blue(self.alias)})" if self.alias
          io.print " | #{Style.green(description)}" if description
          io.puts
          io.print Style.yellow(cmd_id)
          io.print Style.green.bold(" > ")
          io.puts Style.yellow(cmd)
        elsif App.instance.warn? && description
          io.print Style.blue(host)
          io.print " (#{Style.blue(self.alias)})" if self.alias
          io.print " | #{Style.green(description)}" if description
          io.puts
        end
        io.string
      end
      puts output_block unless output_block.empty?

      return unless cmd && !cmd.strip.empty?

      t1 = Time.now
      output, stderr, exit_status = if App.instance.dry_run?
        ["", "", 0]
      else
        sshkit_cmd = execute_cmd(cmd, input_mapping: input, ops_prompt_for_sudo_password: ops_prompt_for_sudo_password)
        [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]
      end
      t2 = Time.now
      seconds = t2 - t1

      stdout, remote_ops_script_retval = parse_stdout_and_script_return_value(output)

      output_block = StringIO.open do |io|
        if App.instance.info?   # this is true if log_level is trace, debug, info
          if App.instance.trace?
            io.puts Style.cyan(stdout)
            io.puts Style.red(stderr)
          elsif App.instance.debug?
            io.puts Style.cyan(stdout)
            io.puts Style.red(stderr)
          elsif App.instance.info?
            io.puts Style.cyan(stdout)
            io.puts Style.red(stderr)
          end
          io.print Style.yellow(cmd_id)
          io.print Style.blue(" | Finished in #{seconds} seconds with exit status ")
          if exit_status == 0
            io.puts Style.green("#{exit_status} (success)")
          else
            io.puts Style.red("#{exit_status} (failure)")
          end
          io.puts Style.green("*" * 80)
        elsif App.instance.warn? && description
          io.print Style.blue("Finished in #{seconds} seconds with exit status ")
          if exit_status == 0
            io.puts Style.green("#{exit_status} (success)")
          else
            io.puts Style.red("#{exit_status} (failure)")
          end
          io.puts Style.green("*" * 80)
        end
        io.string
      end
      puts output_block unless output_block.empty?

      out = remote_ops_script_retval || stdout
      [out, stderr, exit_status]
    end

    def parse_stdout_and_script_return_value(command_output)
      output_sections = command_output.split(/#{::OpsWalrus::App::SCRIPT_RESULT_HEADER}/)
      case output_sections.count
      when 1
        stdout, ops_script_retval = output_sections.first, nil
        # puts "found it1!: #{output_sections.inspect}"
      when 2
        stdout, ops_script_retval = *output_sections
        # puts "found it2!: #{ops_script_retval}"
      else
        # this is unexpected
        ops_script_retval = output_sections.pop
        stdout = output_sections.join(::OpsWalrus::App::SCRIPT_RESULT_HEADER)
        # puts "found it3!: #{ops_script_retval}"
      end
      [stdout, ops_script_retval]
    end

    # runs the specified ops command with the specified command arguments
    # returns [stdout, stderr, exit_status]
    def run_ops(ops_command, ops_command_options = nil, command_arguments, in_bundle_root_dir: true, ops_prompt_for_sudo_password: false)
      local_hostname_for_remote_host = if self.alias
        "#{host} (#{self.alias})"
      else
        host
      end

      # cmd = "OPS_GEM=\"#{OPS_GEM}\" OPSWALRUS_LOCAL_HOSTNAME='#{local_hostname_for_remote_host}'; $OPS_GEM exec --conservative -g opswalrus ops"
      cmd = "OPSWALRUS_LOCAL_HOSTNAME='#{local_hostname_for_remote_host}' eval #{OPS_CMD}"
      if App.instance.trace?
        cmd << " --loudest"
      elsif App.instance.debug?
        cmd << " --louder"
      elsif App.instance.info?
        cmd << " --loud"
      end
      cmd << " #{ops_command.to_s}"
      cmd << " #{ops_command_options.to_s}" if ops_command_options
      cmd << " #{@tmp_bundle_root_dir}" if in_bundle_root_dir
      cmd << " #{command_arguments}" unless command_arguments.empty?

      shell!(cmd, ops_prompt_for_sudo_password: ops_prompt_for_sudo_password)
    end

    def desc(msg)
      puts Style.green(msg.mustache(2))    # we use two here, because one stack frame accounts for the call from the ops script into HostProxy#desc
    end

    def warn(msg)
      puts Style.yellow(msg.mustache(2))    # we use two here, because one stack frame accounts for the call from the ops script into HostProxy#desc
    end

    def debug(msg)
      puts msg.mustache(2) if App.instance.debug? || App.instance.trace?    # we use two here, because one stack frame accounts for the call from the ops script into HostProxy#desc
    end

    def env(*args, **kwargs)
      @ops_file_script.env(*args, **kwargs)
    end

    def params(*args, **kwargs)
      @ops_file_script.params(*args, **kwargs)
    end

    def host_prop(name)
      @props[name] || @default_props[name]
    end

    def ssh_session
      @sshkit_backend
    end

  end

  class Host
    include HostDSL

    # ssh_uri is a string of the form:
    # - hostname
    # - user@hostname
    # - hostname:port
    # - user@hostname:port
    def initialize(ssh_uri, tags = [], props = {}, default_props = {}, hosts_file = nil)
      @ssh_uri = ssh_uri
      @host = nil
      @tags = tags.to_set
      @props = props.is_a?(Array) ? {"tags" => props} : props.to_h
      @default_props = default_props
      @hosts_file = hosts_file
      @tmp_ssh_key_files = []
      parse_ssh_uri!
    end

    def parse_ssh_uri!
      if match = /^\s*((?<user>.*?)@)?(?<host>.*?)(:(?<port>[0-9]+))?\s*$/.match(@ssh_uri)
        @host ||= match[:host] if match[:host]
        @props["user"] ||= match[:user] if match[:user]
        @props["port"] ||= match[:port].to_i if match[:port]
      end
    end

    # secret_ref: SecretRef
    # returns the decrypted value referenced by the supplied SecretRef
    def dereference_secret_if_needed(secret_ref)
      if secret_ref.is_a? SecretRef
        raise "Host #{self} not read from hosts file so no secrets can be dereferenced." unless @hosts_file
        @hosts_file.read_secret(secret_ref.to_s)
      else
        secret_ref
      end
    end

    def ssh_uri
      @ssh_uri
    end

    def host
      @host
    end

    def alias
      @props["alias"] || @default_props["alias"]
    end

    def ignore?
      @props["ignore"] || @default_props["ignore"]
    end

    def ssh_port
      @props["port"] || @default_props["port"] || 22
    end

    def ssh_user
      @props["user"] || @default_props["user"]
    end

    def ssh_password
      password = @props["password"] || @default_props["password"]
      password ||= begin
        @props["password"] = IO::console.getpass("[opswalrus] Please enter ssh password to connect to #{ssh_user}@#{host}:#{ssh_port}: ")
      end
      dereference_secret_if_needed(password)
    end

    def ssh_key
      @props["ssh-key"] || @default_props["ssh-key"]
    end

    def hash
      @ssh_uri.hash
    end

    def eql?(other)
      self.class == other.class && self.hash == other.hash
    end

    def to_s
      @ssh_uri
    end

    def tag!(*tags)
      enumerables, scalars = tags.partition {|t| Enumerable === t }
      @tags.merge(scalars)
      enumerables.each {|enum| @tags.merge(enum) }
      @tags
    end

    def tags
      @tags
    end

    def summary(verbose = false)
      report = "#{to_s}\n  tags: #{tags.sort.join(', ')}"
      if verbose
        @default_props.merge(@props).reject{|k,v| k == 'tags' }.each {|k,v| report << "\n  #{k}: #{v}" }
      end
      report
    end

    def sshkit_host
      keys = case ssh_key
      when Array
        ssh_key
      else
        [ssh_key]
      end
      keys = write_temp_ssh_keys_if_needed(keys)

      # the various options for net-ssh are captured in https://net-ssh.github.io/ssh/v1/chapter-2.html
      @sshkit_host ||= ::SSHKit::Host.new({
        hostname: host,
        port: ssh_port,
        user: ssh_user || raise("No ssh user specified to connect to #{host}"),
        password: ssh_password,
        keys: keys
      })
    end

    # keys is an Array ( String | SecretRef )
    # such that if a key is a String, then it is interpreted as a path to a key file
    # and if the key is a SecretRef, then the secret's plaintext value is interpreted
    # as an ssh key string, and must thereforce be written to a tempfile so that net-ssh
    # can use it via file reference (since net-ssh only allows the keys field to be an array of file paths).
    #
    # returns an array of file paths to key files
    def write_temp_ssh_keys_if_needed(keys)
      keys.map do |key_file_path_or_in_memory_key_text|
        if key_file_path_or_in_memory_key_text.is_a? SecretRef    # we're dealing with an in-memory key file; we need to write it to a tempfile
          tempfile = Tempfile.create
          @tmp_ssh_key_files << tempfile
          raise "Host #{self} not read from hosts file so no secrets can be written." unless @hosts_file
          key_file_contents = @hosts_file.read_secret(key_file_path_or_in_memory_key_text.to_s)
          tempfile.write(key_file_contents)
          tempfile.close   # we want to close the file without unlinking so that the editor can write to it
          tempfile.path
        else    # we're dealing with a reference to a keyfile - a path - so return it
          key_file_path_or_in_memory_key_text
        end
      end
    end

    def set_runtime_env(runtime_env)
      @runtime_env = runtime_env
    end

    def set_ops_file_script(ops_file_script)
      @ops_file_script = ops_file_script
    end

    def set_ssh_session_connection(sshkit_backend)
      @sshkit_backend = sshkit_backend
    end

    def set_ssh_session_tmp_bundle_root_dir(tmp_bundle_root_dir)
      @tmp_bundle_root_dir = tmp_bundle_root_dir
    end

    # returns the temporary bundle root directory
    def _initialize_session
      # copy over ops bundle zip file
      zip_bundle_path = @runtime_env.zip_bundle_path
      upload_success = upload(zip_bundle_path, "tmpops.zip")
      raise Error, "Unable to upload ops bundle to remote host" unless upload_success

      stdout, _stderr, exit_status = run_ops(:bundle, "unzip tmpops.zip", in_bundle_root_dir: false)
      raise Error, "Unable to unzip ops bundle on remote host: #{stdout}" unless exit_status == 0
      tmp_bundle_root_dir = stdout.strip
      set_ssh_session_tmp_bundle_root_dir(tmp_bundle_root_dir)
    end

    def _cleanup_session
      # todo: cleanup
      if @tmp_bundle_root_dir =~ /tmp/   # sanity check the temp path before we blow away something we don't intend
        execute(:rm, "-rf", "tmpops.zip", @tmp_bundle_root_dir)
      else
        execute(:rm, "-rf", "tmpops.zip")
      end
    end

    def clear_ssh_session
      @runtime_env = nil
      @ops_file_script = nil
      @sshkit_backend = nil
      @tmp_bundle_root_dir = nil
      @tmp_ssh_key_files.each {|tmpfile| tmpfile.close() rescue nil; File.unlink(tmpfile) rescue nil }
      @tmp_ssh_key_files = []
    end

    def execute(*args, input_mapping: nil, ops_prompt_for_sudo_password: false)
      sudo_password_args = {}
      sudo_password_args[:sudo_password] = ssh_password unless ops_prompt_for_sudo_password
      sudo_password_args[:ops_sudo_password] = ssh_password if ops_prompt_for_sudo_password
      @runtime_env.handle_input(input_mapping, **sudo_password_args, inherit_existing_mappings: false) do |interaction_handler|
        # @sshkit_backend.capture(*args, interaction_handler: interaction_handler, verbosity: SSHKit.config.output_verbosity)
        App.instance.debug("Host#execute_cmd(#{args.inspect}) with input mappings #{interaction_handler.input_mappings.inspect} given sudo_password_args: #{sudo_password_args.inspect})")
        @sshkit_backend.capture(*args, interaction_handler: interaction_handler)
      end
    end

    # Returns a SSHKit::Command
    def execute_cmd(*args, input_mapping: nil, ops_prompt_for_sudo_password: false)
      # we only want one of the sudo password interaction handlers:
      # if we're running an ops script on the remote host and we've passed the --pass flag in our invocation of the ops command on the remote host,
      #   then we want to specify the sudo password via the ops_sudo_password argument to #handle_input
      # if we're running a command on the remote host via #shell!, and we aren't running the ops command with the --pass flag,
      #   then we want to specify the sudo password via the sudo_password argument to #handle_input
      sudo_password_args = {}
      sudo_password_args[:sudo_password] = ssh_password unless ops_prompt_for_sudo_password
      sudo_password_args[:ops_sudo_password] = ssh_password if ops_prompt_for_sudo_password
      @runtime_env.handle_input(input_mapping, **sudo_password_args, inherit_existing_mappings: false) do |interaction_handler|
        App.instance.debug("Host#execute_cmd(#{args.inspect}) with input mappings #{interaction_handler.input_mappings.inspect} given sudo_password_args: #{sudo_password_args.inspect})")
        @sshkit_backend.execute_cmd(*args, interaction_handler: interaction_handler)
      end
    end

    def upload(local_path_or_io, remote_path)
      source = local_path_or_io.is_a?(IO) ? local_path_or_io : local_path_or_io.to_s
      @sshkit_backend.upload!(source, remote_path.to_s)
    end

    def download(remote_path, local_path)
      @sshkit_backend.download!(remote_path.to_s, local_path.to_s)
    end

    def to_h
      hash = {}
      hash["alias"] = @props["alias"] if @props["alias"]
      hash["ignore"] = @props["ignore"] if @props["ignore"]
      hash["user"] = @props["user"] if @props["user"]
      hash["port"] = @props["port"] if @props["port"]
      hash["password"] = @props["password"] if @props["password"]
      hash["ssh-key"] = @props["ssh-key"] if @props["ssh-key"]
      hash["tags"] = tags.to_a unless tags.empty?
      hash
    end
  end

end
