require 'json'
require 'tempfile'

module OpsWalrus

  class ImportInvocationContext
    def _invoke(*args, **kwargs)
      raise "Not implemented in base class"
    end

    def _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs, &block)
      raise "Not implemented in base class"
    end

    def method_missing(name, *args, **kwargs, &block)
      raise "Not implemented in base class"
    end

    def _bang_method?(name)
      name.to_s.end_with?("!")
    end

    def _non_bang_method(name)
      name.to_s.sub(/!$/, '')
    end

    # define methods that exist on kernel and forward them to the method_missing call because
    # we want method_missing to handle the calls that may result from navigating through a package's
    # directory structure (e.g. we include clone here to handle core.git.clone which conflicts with Kernel#clone)
    [:clone].each do |symbol_name|
      define_method(symbol_name) do |*args, **kwargs, &block|
        method_missing(symbol_name, *args, **kwargs, &block)
      end
    end
  end

  class RemoteImportInvocationContext < ImportInvocationContext
    def initialize(runtime_env, host_proxy, namespace_or_ops_file, is_invocation_a_call_to_package_in_bundle_dir = false, ops_prompt_for_sudo_password: nil)
      @runtime_env = runtime_env
      @host_proxy = host_proxy
      @initial_namespace_or_ops_file = @namespace_or_ops_file = namespace_or_ops_file
      @is_invocation_a_call_to_package_in_bundle_dir = is_invocation_a_call_to_package_in_bundle_dir

      initial_method_name = case @namespace_or_ops_file
      when Namespace
        @namespace_or_ops_file.dirname.basename
      when OpsFile
        @namespace_or_ops_file.basename
      end
      @method_chain = [initial_method_name]
      @ops_prompt_for_sudo_password = ops_prompt_for_sudo_password
    end

    def method_missing(name, *args, **kwargs, &block)
      _resolve_method_and_invoke(name, *args, **kwargs)
    end

    def _resolve_method_and_invoke(name, *args, **kwargs)
      if _bang_method?(name)      # foo! is an attempt to invoke the module's default entrypoint
        method_name = _non_bang_method(name)

        @method_chain << method_name

        @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(method_name)
        _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs)
      else
        @method_chain << name.to_s

        @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(name)
        _invoke(*args, **kwargs)
      end
    end

    # if this namespace contains an OpsFile of the same name as the namespace, e.g. pkg/install/install.ops, then this
    # method invokes the OpsFile of that same name and returns the result;
    # otherwise we return this namespace object
    def _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs, &block)
      method_name = @namespace_or_ops_file.dirname.basename
      resolved_symbol = @namespace_or_ops_file.resolve_symbol(method_name)
      if resolved_symbol.is_a? OpsFile
        _resolve_method_and_invoke(method_name)
      else
        self
      end
    end

    def _invoke(*args, **kwargs)
      case @namespace_or_ops_file
      when Namespace
        self
      when OpsFile
        _invoke_remote(*args, **kwargs)
      end
    end

    def _invoke_remote(*args, **kwargs)
      # when there are args or kwargs, then the method invocation represents an attempt to run an OpsFile on a remote host,
      # so we want to build up a command and send it to the remote host via HostDSL#run_ops
      @method_chain.unshift(Bundler::BUNDLE_DIR) if @is_invocation_a_call_to_package_in_bundle_dir

      remote_run_command_args = @method_chain.join(" ")

      unless args.empty?
        remote_run_command_args << " "
        remote_run_command_args << args.join(" ")
      end

      # unless kwargs.empty?
      #   remote_run_command_args << " "
      #   remote_run_command_args << kwargs.map do |k, v|
      #     case v
      #     when Array
      #       v.map {|v_element| "#{k}:#{v_element}" }
      #     else
      #       "#{k}:#{v}"
      #     end
      #   end.join(" ")
      # end
      begin
        json = JSON.dump(kwargs) unless kwargs.empty?
        if json
          # write the kwargs to a tempfile
          json_kwargs_tempfile = Tempfile.create('ops_invoke_kwargs')
          json_kwargs_tempfile.write(json)
          json_kwargs_tempfile.close()   # we want to close the file without unlinking so that we can copy it to the remote host before deleting it

          # upload the kwargs file to the remote host
          json_kwargs_tempfile_path = json_kwargs_tempfile.path.to_pathname
          remote_json_kwargs_tempfile_basename = json_kwargs_tempfile_path.basename
          @host_proxy.upload(json_kwargs_tempfile_path, remote_json_kwargs_tempfile_basename)
        end

        # invoke the ops command on the remote host to run the specified ops script on the remote host
        ops_command_options = "--script"
        ops_command_options << " --pass" if @ops_prompt_for_sudo_password
        ops_command_options << " --params #{remote_json_kwargs_tempfile_basename}" if remote_json_kwargs_tempfile_basename

        output, stderr, exit_status = if ops_command_options.empty?
          @host_proxy.run_ops(:run, remote_run_command_args, ops_prompt_for_sudo_password: @ops_prompt_for_sudo_password)
        else
          @host_proxy.run_ops(:run, ops_command_options, remote_run_command_args, ops_prompt_for_sudo_password: @ops_prompt_for_sudo_password)
        end

        App.instance.debug("Remote invocation failed:\n  cmd: ops run #{ops_command_options.to_s} #{remote_run_command_args.to_s}\n  stdout: #{output}\n") unless exit_status == 0

        RemoteInvocation.parse_remote_script_invocation_result(output)
      ensure
        if json_kwargs_tempfile
          json_kwargs_tempfile.close rescue nil
          File.unlink(json_kwargs_tempfile) rescue nil
        end
        # todo: make sure this cleanup is present
        if remote_json_kwargs_tempfile_basename
          @host_proxy.execute(:rm, "-f", remote_json_kwargs_tempfile_basename)
        end
      end
    end
  end

  class LocalImportInvocationContext < ImportInvocationContext
    def initialize(runtime_env, namespace_or_ops_file)
      @runtime_env = runtime_env
      @initial_namespace_or_ops_file = @namespace_or_ops_file = namespace_or_ops_file
    end

    def method_missing(name, *args, **kwargs, &block)
      _resolve_method_and_invoke(name, *args, **kwargs)
    end

    def _resolve_method_and_invoke(name, *args, **kwargs)
      if _bang_method?(name)      # foo! is an attempt to invoke the module's default entrypoint
        method_name = _non_bang_method(name)
        @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(method_name)
        _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs)
      else
        @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(name)
        _invoke(*args, **kwargs)
      end
    end

    # if this namespace contains an OpsFile of the same name as the namespace, e.g. pkg/install/install.ops, then this
    # method invokes the OpsFile of that same name and returns the result;
    # otherwise we return this namespace object
    def _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs)
      method_name = @namespace_or_ops_file.dirname.basename
      resolved_symbol = @namespace_or_ops_file.resolve_symbol(method_name)
      if resolved_symbol.is_a? OpsFile
        params_hash = resolved_symbol.build_params_hash(*args, **kwargs)
        resolved_symbol.invoke(@runtime_env, params_hash)
      else
        self
      end
    end

    def _invoke(*args, **kwargs)
      case @namespace_or_ops_file
      when Namespace
        self
      when OpsFile
        _invoke_local(*args, **kwargs)
      end
    end

    def _invoke_local(*args, **kwargs)
      params_hash = @namespace_or_ops_file.build_params_hash(*args, **kwargs)
      @namespace_or_ops_file.invoke(@runtime_env, params_hash)
    end

  end



  class RemoteInvocation
    def self.parse_remote_script_invocation_result(json_string)
      retval = JSON.parse(json_string)
      case retval
      when Hash
        if retval["type"] == Invocation::Error::Type
          # this structure comes from OpsWalrus::Invocation::Error being serialized in App#print_script_result being called from App#run
          # {
          #   type: "Invocation::Error",
          #   error_variant: self.class.name,
          #   error_class: value.class.name,
          #   error: value,
          #   backtrace: value.is_a?(Exception) ? value.backtrace.take(10).join("\n") : nil,
          #   exit_status: exit_status
          # }
          # raise RemoteInvocationError.new("Remote Invocation Error:\n  #{retval["error_class"]}: #{retval["error"]}#{retval["backtrace"] && "\n  Backtrace: #{retval['backtrace']}"}")

          if retval["error_variant"] == Invocation::EarlyExitError.name && retval["exit_status"] == ExitCodeHostTemporarilyUnavailable
            raise RetriableRemoteInvocationError.new("Retriable Remote Invocation Error (exit_status=#{retval["exit_status"]}):\n  #{retval["error_class"]}: #{retval["error"]}#{retval["backtrace"] && "\n  Backtrace: #{retval['backtrace']}"}", retval)
          else
            raise RemoteInvocationError.new("Remote Invocation Error (exit_status=#{retval["exit_status"]}):\n  #{retval["error_class"]}: #{retval["error"]}#{retval["backtrace"] && "\n  Backtrace: #{retval['backtrace']}"}", retval)
          end
        else
          retval.with_indifferent_access.easynav
        end
      when Array
        retval.easynav
      else
        retval
      end
    end

    def initialize(host_proxy, ops_file, ops_prompt_for_sudo_password: nil)
      @host_proxy = host_proxy
      @ops_file = ops_file
      @ops_prompt_for_sudo_password = ops_prompt_for_sudo_password
    end

    def invoke(*args, **kwargs)
      # when there are args or kwargs, then the method invocation represents an attempt to run an OpsFile on a remote host,
      # so we want to build up a command and send it to the remote host via HostDSL#run_ops
      remote_run_command_args = @ops_file.relative_path_to_app_pwd.to_s

      unless args.empty?
        remote_run_command_args << " "
        remote_run_command_args << args.join(" ")
      end

      begin
        json = JSON.dump(kwargs) unless kwargs.empty?
        if json
          # write the kwargs to a tempfile
          json_kwargs_tempfile = Tempfile.create('ops_invoke_kwargs')
          json_kwargs_tempfile.write(json)
          json_kwargs_tempfile.close()   # we want to close the file without unlinking so that we can copy it to the remote host before deleting it

          # upload the kwargs file to the remote host
          json_kwargs_tempfile_path = json_kwargs_tempfile.path.to_pathname
          remote_json_kwargs_tempfile_basename = json_kwargs_tempfile_path.basename
          @host_proxy.upload(json_kwargs_tempfile_path, remote_json_kwargs_tempfile_basename)
        end

        # invoke the ops command on the remote host to run the specified ops script on the remote host
        ops_command_options = "--script"
        ops_command_options << " --pass" if @ops_prompt_for_sudo_password
        ops_command_options << " --params #{remote_json_kwargs_tempfile_basename}" if remote_json_kwargs_tempfile_basename

        output, stderr, exit_status = if ops_command_options.empty?
          @host_proxy.run_ops(:run, remote_run_command_args, ops_prompt_for_sudo_password: @ops_prompt_for_sudo_password)
        else
          @host_proxy.run_ops(:run, ops_command_options, remote_run_command_args, ops_prompt_for_sudo_password: @ops_prompt_for_sudo_password)
        end

        App.instance.debug("Remote invocation failed:\n  cmd: ops run #{ops_command_options.to_s} #{remote_run_command_args.to_s}\n  stdout: #{output}\n") unless exit_status == 0

        RemoteInvocation.parse_remote_script_invocation_result(output)
      ensure
        if json_kwargs_tempfile
          json_kwargs_tempfile.close rescue nil
          File.unlink(json_kwargs_tempfile) rescue nil
        end
        # todo: make sure this cleanup is present
        if remote_json_kwargs_tempfile_basename
          @host_proxy.execute(:rm, "-f", remote_json_kwargs_tempfile_basename)
        end
      end
    end
  end
end
