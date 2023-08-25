require "set"
require "sshkit"

require_relative "interaction_handlers"
require_relative "invocation"

module OpsWalrus

  OPS_GEM="$HOME/.local/share/rtx/shims/gem"
  OPS_CMD="$HOME/.local/share/rtx/shims/ops"

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
            when PackageDependencyReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, true, prompt_for_sudo_password: !!ssh_password)

            # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
            # the specified ops file with respect to the root directory, and not with respect to the bundle dir
            when DirectoryReference, OpsFileReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false, prompt_for_sudo_password: !!ssh_password)
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
          # puts "2. defining: #{symbol_name}(...)"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.trace "resolving implicit import: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_sibling_symbol(ops_file, symbol_name)
            App.instance.trace "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false, prompt_for_sudo_password: !!ssh_password)
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

    def _bootstrap_host
      # copy over bootstrap shell script
      # io = StringIO.new(bootstrap_shell_script)
      io = File.open(__FILE__.to_pathname.dirname.join("bootstrap.sh"))
      upload_success = @_host.upload(io, "tmpopsbootstrap.sh")
      io.close
      raise Error, "Unable to upload bootstrap shell script to remote host #{to_s} (alias=#{self.alias})" unless upload_success
      @_host.execute(:chmod, "755", "tmpopsbootstrap.sh")
      @_host.execute(:sh, "tmpopsbootstrap.sh")
      @_host.execute(:rm, "-f", "tmpopsbootstrap.sh")
    end

    def _zip_copy_and_run_ops_bundle(local_host, block)
      # copy over ops bundle zip file
      zip_bundle_path = @runtime_env.zip_bundle_path
      upload_success = @_host.upload(zip_bundle_path, "tmpops.zip")
      raise Error, "Unable to upload ops bundle to remote host" unless upload_success

      stdout, _stderr, exit_status = @_host.run_ops(:bundle, "unzip tmpops.zip", in_bundle_root_dir: false)
      raise Error, "Unable to unzip ops bundle on remote host" unless exit_status == 0
      tmp_bundle_root_dir = stdout.strip
      @_host.set_ssh_session_tmp_bundle_root_dir(tmp_bundle_root_dir)

      # we run the block in the context of the host proxy object, s.t. `self` within the block evaluates to the host proxy object
      retval = instance_exec(local_host, &block)    # local_host is passed as the argument to the block

      # todo: cleanup
      # if tmp_bundle_root_dir =~ /tmp/   # sanity check the temp path before we blow away something we don't intend
      #   @_host.execute(:rm, "-rf", "tmpops.zip", tmp_bundle_root_dir)
      # else
      #   @_host.execute(:rm, "-rf", "tmpops.zip")
      # end

      retval
    end

    def method_missing(name, ...)
      @_host.send(name, ...)
    end
  end


  module HostDSL
    # returns the stdout from the command
    def sh(desc_or_cmd = nil, cmd = nil, input: nil, &block)
      out, err, status = *shell!(desc_or_cmd, cmd, block, input: input)
      out
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell(desc_or_cmd = nil, cmd = nil, input: nil, &block)
      shell!(desc_or_cmd, cmd, block, input: input)
    end

    # returns the tuple: [stdout, stderr, exit_status]
    def shell!(desc_or_cmd = nil, cmd = nil, block = nil, input: nil)
      # description = nil

      return ["", "", 0] if !desc_or_cmd && !cmd && !block    # we were told to do nothing; like hitting enter at the bash prompt; we can do nothing successfully

      description = desc_or_cmd if cmd || block
      description = WalrusLang.render(description, block.binding) if description && block
      cmd = block.call if block
      cmd ||= desc_or_cmd

      cmd = WalrusLang.render(cmd, block.binding) if block && cmd =~ /{{.*}}/

      #cmd = Shellwords.escape(cmd)

      if App.instance.report_mode?
        puts Style.green("*" * 80)
        if self.alias
          print "[#{Style.blue(self.alias)} | #{Style.blue(host)}] "
        else
          print "[#{Style.blue(host)}] "
        end
        print "#{description}: " if description
        puts Style.yellow(cmd)
      end

      return unless cmd && !cmd.strip.empty?

      # puts "shell: #{cmd}"
      # puts "shell: #{cmd.inspect}"
      # puts "sudo_password: #{sudo_password}"

      if App.instance.dry_run?
        ["", "", 0]
      else
        sshkit_cmd = execute_cmd(cmd, input: input)
        [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]
      end
    end

    # def init_brew
    #   execute('eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"')
    # end

    # runs the specified ops command with the specified command arguments
    def run_ops(ops_command, ops_command_options = nil, command_arguments, in_bundle_root_dir: true, verbose: false)
      # e.g. /home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops bundle unzip tmpops.zip
      # e.g. /home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops run echo.ops args:foo args:bar

      # cmd = "/home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops"
      local_hostname_for_remote_host = if self.alias
        "#{self.alias} | #{host}"
      else
        host
      end

      # cmd = "OPSWALRUS_LOCAL_HOSTNAME='#{local_hostname_for_remote_host}'; /home/linuxbrew/.linuxbrew/bin/gem exec --conservative -g opswalrus ops"
      # cmd = "OPS_GEM=\"#{OPS_GEM}\" OPSWALRUS_LOCAL_HOSTNAME='#{local_hostname_for_remote_host}'; $OPS_GEM exec --conservative -g opswalrus ops"
      cmd = "OPSWALRUS_LOCAL_HOSTNAME='#{local_hostname_for_remote_host}'; #{OPS_CMD}"
      cmd << " -v" if verbose
      cmd << " #{ops_command.to_s}"
      cmd << " #{ops_command_options.to_s}" if ops_command_options
      cmd << " #{@tmp_bundle_root_dir}" if in_bundle_root_dir
      cmd << " #{command_arguments}" unless command_arguments.empty?

      shell!(cmd)
    end

  end

  class Host
    include HostDSL

    def initialize(name_or_ip_or_cidr, tags = [], props = {})
      @name_or_ip_or_cidr = name_or_ip_or_cidr
      @tags = tags.to_set
      @props = props.is_a?(Array) ? {"tags" => props} : props.to_h
    end

    def host
      @name_or_ip_or_cidr
    end

    def ssh_port
      @props["port"]
    end

    def ssh_user
      @props["user"]
    end

    def ssh_password
      @props["password"]
    end

    def ssh_keys
      @props["keys"]
    end

    def hash
      @name_or_ip_or_cidr.hash
    end

    def eql?(other)
      self.class == other.class && self.hash == other.hash
    end

    def to_s
      @name_or_ip_or_cidr
    end

    def alias
      @props["alias"]
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
        @props.reject{|k,v| k == 'tags' }.each {|k,v| report << "\n  #{k}: #{v}" }
      end
      report
    end

    def sshkit_host
      @sshkit_host ||= ::SSHKit::Host.new({
        hostname: host,
        port: ssh_port || 22,
        user: ssh_user || raise("No ssh user specified to connect to #{host}"),
        password: ssh_password,
        keys: ssh_keys
      })
    end

    def set_runtime_env(runtime_env)
      @runtime_env = runtime_env
    end

    def set_ssh_session_connection(sshkit_backend)
      @sshkit_backend = sshkit_backend
    end

    def set_ssh_session_tmp_bundle_root_dir(tmp_bundle_root_dir)
      @tmp_bundle_root_dir = tmp_bundle_root_dir
    end

    def clear_ssh_session
      @runtime_env = nil
      @sshkit_backend = nil
      @tmp_bundle_root_dir = nil
    end

    def execute(*args, input: nil)
      @runtime_env.handle_input(input, ssh_password) do |interaction_handler|
        @sshkit_backend.capture(*args, interaction_handler: interaction_handler, verbosity: :info)
      end
    end

    def execute_cmd(*args, input: nil)
      @runtime_env.handle_input(input, ssh_password) do |interaction_handler|
        @sshkit_backend.execute_cmd(*args, interaction_handler: interaction_handler, verbosity: :info)
      end
    end

    def upload(local_path_or_io, remote_path)
      source = local_path_or_io.is_a?(IO) ? local_path_or_io : local_path_or_io.to_s
      @sshkit_backend.upload!(source, remote_path.to_s)
    end

    def download(remote_path, local_path)
      @sshkit_backend.download!(remote_path.to_s, local_path.to_s)
    end

  end

end
