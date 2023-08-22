require 'set'
require_relative 'invocation'
require_relative 'ops_file_script_dsl'

module OpsWalrus

  class OpsFileScript

    def self.define_for(ops_file, ruby_script)
      klass = Class.new(OpsFileScript)

      methods_defined = Set.new

      # define methods for the OpsFile's local_symbol_table: local imports and private lib directory
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          App.instance.debug "defining method for local symbol table entry: #{symbol_name}"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.debug "resolving local symbol table entry: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_import_reference(ops_file, import_reference)
            App.instance.debug "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = LocalImportInvocationContext.new(@runtime_env, namespace_or_ops_file)
            invocation_context._invoke(*args, **kwargs)

          end
          methods_defined << symbol_name
        end
      end

      # define methods for every Namespace or OpsFile within the namespace that the OpsFile resides within
      sibling_symbol_table_names = Set.new
      sibling_symbol_table_names |= ops_file.dirname.glob("*.ops").map {|ops_file_path| ops_file_path.basename(".ops").to_s }   # OpsFiles
      sibling_symbol_table_names |= ops_file.dirname.glob("*").select(&:directory?).map {|dir_path| dir_path.basename.to_s }    # Namespaces
      # puts "sibling_symbol_table_names=#{sibling_symbol_table_names}"
      App.instance.debug "methods_defined=#{methods_defined}"
      sibling_symbol_table_names.each do |symbol_name|
        unless methods_defined.include? symbol_name
          App.instance.debug "defining method for implicit imports: #{symbol_name}"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.debug "resolving implicit import: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_sibling_symbol(ops_file, symbol_name)
            App.instance.debug "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

            invocation_context = LocalImportInvocationContext.new(@runtime_env, namespace_or_ops_file)
            invocation_context._invoke(*args, **kwargs)

          end
          methods_defined << symbol_name
        end
      end

      # the evaluation context needs to be a module with all of the following:
      # - OpsFileScriptDSL methods
      # - @runtime_env
      # - @params
      # - #host_proxy_class
      # - #backend
      # - #debug?
      # - #verbose?
      # - all the dynamically defined methods in the subclass of Invocation
      invoke_method_definition = <<~INVOKE_METHOD
        def _invoke(runtime_env, params_hash)
          @runtime_env = runtime_env
          @params = InvocationParams.new(params_hash)
          #{ruby_script}
        end
      INVOKE_METHOD

      invoke_method_line_count_prior_to_ruby_script_from_ops_file = 3
      klass.module_eval(invoke_method_definition, ops_file.ops_file_path.to_s, ops_file.script_line_offset - invoke_method_line_count_prior_to_ruby_script_from_ops_file)

      klass
    end


    include OpsFileScriptDSL

    attr_accessor :ops_file

    def initialize(ops_file, ruby_script)
      @ops_file = ops_file
      @script = ruby_script
      @runtime_env = nil    # this is set at the very first line of #_invoke
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

    def host_proxy_class
      @ops_file.host_proxy_class
    end

    # The _invoke method is dynamically defined as part of OpsFileScript.define_for
    def _invoke(runtime_env, params_hash)
      raise "Not implemented in base class."
    end

    def to_s
      @script
    end
  end

end
