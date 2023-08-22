
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
  end

  class RemoteImportInvocationContext < ImportInvocationContext
    def initialize(runtime_env, host_proxy, namespace_or_ops_file, is_invocation_a_call_to_package_in_bundle_dir = false)
      @runtime_env = runtime_env
      @host_proxy = host_proxy
      @initial_namespace_or_ops_file = @namespace_or_ops_file = namespace_or_ops_file
      @is_invocation_a_call_to_package_in_bundle_dir = is_invocation_a_call_to_package_in_bundle_dir

      initial_method_name = @namespace_or_ops_file.dirname.basename
      @method_chain = [initial_method_name]
    end

    def _invoke(*args, **kwargs)
      case @namespace_or_ops_file
      when Namespace
        _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs)
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

      @host_proxy.run_ops(:run, "--script", remote_run_command_args)
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

    def _resolve_method_and_invoke(name, *args, **kwargs)
      @method_chain << name.to_s

      @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(name)
      _invoke(*args, **kwargs)
    end

    def method_missing(name, *args, **kwargs, &block)
      _resolve_method_and_invoke(name, *args, **kwargs)
    end
  end

  class LocalImportInvocationContext < ImportInvocationContext
    def initialize(runtime_env, namespace_or_ops_file)
      @runtime_env = runtime_env
      @initial_namespace_or_ops_file = @namespace_or_ops_file = namespace_or_ops_file
    end

    def _invoke(*args, **kwargs)
      case @namespace_or_ops_file
      when Namespace
        _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs)
      when OpsFile
        _invoke_local(*args, **kwargs)
      end
    end

    def _invoke_local(*args, **kwargs)
      params_hash = @namespace_or_ops_file.build_params_hash(*args, **kwargs)
      @namespace_or_ops_file.invoke(@runtime_env, params_hash)
    end

    # if this namespace contains an OpsFile of the same name as the namespace, e.g. pkg/install/install.ops, then this
    # method invokes the OpsFile of that same name and returns the result;
    # otherwise we return this namespace object
    def _invoke_if_namespace_has_ops_file_of_same_name(*args, **kwargs, &block)
      method_name = @namespace_or_ops_file.dirname.basename
      resolved_symbol = @namespace_or_ops_file.resolve_symbol(method_name)
      if resolved_symbol.is_a? OpsFile
        params_hash = resolved_symbol.build_params_hash(*args, **kwargs)
        resolved_symbol.invoke(@runtime_env, params_hash)
      else
        self
      end
    end

    def _resolve_method_and_invoke(name, *args, **kwargs)
      @namespace_or_ops_file = @namespace_or_ops_file.resolve_symbol(name)
      _invoke(*args, **kwargs)
    end

    def method_missing(name, *args, **kwargs, &block)
      _resolve_method_and_invoke(name, *args, **kwargs)
    end
  end

end
