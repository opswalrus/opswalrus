require "set"
require "sshkit"

require_relative "interaction_handlers"
require_relative "invocation"

module OpsWalrus

  class HostProxyOpsFileInvocationBuilder
    def initialize(host_proxy, is_invocation_a_call_to_package_in_bundle_dir = false)
      @host_proxy = host_proxy
      @is_invocation_a_call_to_package_in_bundle_dir = is_invocation_a_call_to_package_in_bundle_dir
      @method_chain = []
    end

    def method_missing(method_name, *args, **kwargs)
      @method_chain << method_name.to_s

      if args.empty? && kwargs.empty?   # when there are no args and no kwargs, we are just drilling down through another namespace
        self
      else
        # when there are args or kwargs, then the method invocation represents an attempt to run an OpsFile on a remote host,
        # so we want to build up a command and send it to the remote host via HostDSL#run_ops
        @method_chain.unshift(Bundler::BUNDLE_DIR) if @is_invocation_a_call_to_package_in_bundle_dir

        remote_run_command_args = @method_chain.join(" ")

        unless args.empty?
          remote_run_command_args << " "
          remote_run_command_args << args.join(" ")
        end

        unless kwargs.empty?
          remote_run_command_args << " "
          remote_run_command_args << kwargs.map do |k, v|
            case v
            when Array
              v.map {|v_element| "#{k}:#{v_element}" }
            else
              "#{k}:#{v}"
            end
          end.join(" ")
        end

        @host_proxy.run_ops(:run, "--script", remote_run_command_args)
      end
    end
  end

  # the subclasses of HostProxy will define methods that handle method dispatch via HostProxyOpsFileInvocationBuilder objects
  class HostProxy
    # def self.define_host_proxy_class(ops_file)
    #   klass = Class.new(HostProxy)

    #   methods_defined = Set.new

    #   # define methods for every import in the script
    #   ops_file.local_symbol_table.each do |symbol_name, import_reference|
    #     unless methods_defined.include? symbol_name
    #       # puts "1. defining: #{symbol_name}(...)"
    #       klass.define_method(symbol_name) do |*args, **kwargs, &block|
    #         invocation_builder = case import_reference
    #         # we know we're dealing with a package dependency reference, so we want to run an ops file contained within the bundle directory,
    #         # therefore, we want to reference the specified ops file with respect to the bundle dir
    #         when PackageDependencyReference
    #           HostProxyOpsFileInvocationBuilder.new(self, true)

    #         # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
    #         # the specified ops file with respect to the root directory, and not with respect to the bundle dir
    #         when DirectoryReference, OpsFileReference
    #           HostProxyOpsFileInvocationBuilder.new(self, false)
    #         end

    #         invocation_builder.send(symbol_name, *args, **kwargs, &block)
    #       end
    #       methods_defined << symbol_name
    #     end
    #   end

    #   # define methods for every Namespace or OpsFile within the namespace that the OpsFile resides within
    #   sibling_symbol_table = Set.new
    #   sibling_symbol_table |= ops_file.dirname.glob("*.ops").map {|ops_file_path| ops_file_path.basename(".ops").to_s }   # OpsFiles
    #   sibling_symbol_table |= ops_file.dirname.glob("*").select(&:directory?).map {|dir_path| dir_path.basename.to_s }    # Namespaces
    #   sibling_symbol_table.each do |symbol_name|
    #     unless methods_defined.include? symbol_name
    #       # puts "2. defining: #{symbol_name}(...)"
    #       klass.define_method(symbol_name) do |*args, **kwargs, &block|
    #         invocation_builder = HostProxyOpsFileInvocationBuilder.new(self, false)
    #         invocation_builder.invoke(symbol_name, *args, **kwargs, &block)
    #       end
    #       methods_defined << symbol_name
    #     end
    #   end

    #   klass
    # end

    def self.define_host_proxy_class(ops_file)
      klass = Class.new(HostProxy)

      methods_defined = Set.new

      # define methods for every import in the script
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            # puts "resolving local symbol table entry: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_import_reference(ops_file, import_reference)
            # puts "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = case import_reference
            # we know we're dealing with a package dependency reference, so we want to run an ops file contained within the bundle directory,
            # therefore, we want to reference the specified ops file with respect to the bundle dir
            when PackageDependencyReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, true)

            # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
            # the specified ops file with respect to the root directory, and not with respect to the bundle dir
            when DirectoryReference, OpsFileReference
              RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false)
            end

            invocation_context._invoke(*args, **kwargs)



            # invocation_builder = case import_reference
            # # we know we're dealing with a package dependency reference, so we want to run an ops file contained within the bundle directory,
            # # therefore, we want to reference the specified ops file with respect to the bundle dir
            # when PackageDependencyReference
            #   HostProxyOpsFileInvocationBuilder.new(self, true)

            # # we know we're dealing with a directory reference or OpsFile reference outside of the bundle dir, so we want to reference
            # # the specified ops file with respect to the root directory, and not with respect to the bundle dir
            # when DirectoryReference, OpsFileReference
            #   HostProxyOpsFileInvocationBuilder.new(self, false)
            # end

            # invocation_builder.send(symbol_name, *args, **kwargs, &block)
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
            # invocation_builder = HostProxyOpsFileInvocationBuilder.new(self, false)
            # invocation_builder.invoke(symbol_name, *args, **kwargs, &block)

            invocation_context = RemoteImportInvocationContext.new(@runtime_env, self, namespace_or_ops_file, false)
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

    # the subclasses of this class will define methods that handle method dispatch via HostProxyOpsFileInvocationBuilder objects

    def to_s
      @_host.to_s
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
      cmd = block.call if block
      cmd ||= desc_or_cmd

      cmd = WalrusLang.render(cmd, block.binding) if block && cmd =~ /{{.*}}/

      #cmd = Shellwords.escape(cmd)

      if App.instance.report_mode?
        if self.alias
          print "[#{self.alias} | #{host}] "
        else
          print "[#{host}] "
        end
        print "#{description}: " if description
        puts cmd
      end

      return unless cmd && !cmd.strip.empty?

      # puts "shell: #{cmd}"
      # puts "shell: #{cmd.inspect}"
      # puts "sudo_password: #{sudo_password}"

      sshkit_cmd = execute_cmd(cmd, input: input)

      [sshkit_cmd.full_stdout, sshkit_cmd.full_stderr, sshkit_cmd.exit_status]
    end

    # def init_brew
    #   execute('eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"')
    # end

    # runs the specified ops command with the specified command arguments
    def run_ops(ops_command, ops_command_options = nil, command_arguments, in_bundle_root_dir: true, verbose: false)
      # e.g. /home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops bundle unzip tmpops.zip
      # e.g. /home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops run echo.ops args:foo args:bar

      # cmd = "/home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops"
      cmd = "/home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops"
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
