
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
  end

  class RemoteImportInvocationContext < ImportInvocationContext
    def initialize(runtime_env, host_proxy, namespace_or_ops_file, is_invocation_a_call_to_package_in_bundle_dir = false, prompt_for_sudo_password: nil)
      @runtime_env = runtime_env
      @host_proxy = host_proxy
      @initial_namespace_or_ops_file = @namespace_or_ops_file = namespace_or_ops_file
      @is_invocation_a_call_to_package_in_bundle_dir = is_invocation_a_call_to_package_in_bundle_dir

      initial_method_name = @namespace_or_ops_file.dirname.basename
      @method_chain = [initial_method_name]
      @prompt_for_sudo_password = prompt_for_sudo_password
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

      # @host_proxy.run_ops(:run, "--script", remote_run_command_args)
      if @prompt_for_sudo_password
        @host_proxy.run_ops(:run, "--pass", remote_run_command_args)
      else
        @host_proxy.run_ops(:run, remote_run_command_args)
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

end
