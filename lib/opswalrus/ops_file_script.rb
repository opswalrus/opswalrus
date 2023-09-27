require 'forwardable'
require 'set'
require_relative 'invocation'
require_relative 'ops_file_script_dsl'

module OpsWalrus

  # class ArrayOrHashNavigationProxy
  #   extend Forwardable

  #   def initialize(array_or_hash)
  #     @obj = array_or_hash
  #   end

  #   def_delegators :@obj, :[], :to_s, :inspect, :hash, :===, :eql?, :kind_of?, :is_a?, :instance_of?, :respond_to?, :<=>

  #   # def [](index, *args, **kwargs, &block)
  #   #   @obj.method(:[]).call(index, *args, **kwargs, &block)
  #   # end
  #   def respond_to_missing?(method, *)
  #     @obj.is_a?(Hash) && @obj.respond_to?(method)
  #   end
  #   def method_missing(name, *args, **kwargs, &block)
  #     case @obj
  #     when Array
  #       @obj.method(name).call(*args, **kwargs, &block)
  #     when Hash
  #       if @obj.respond_to?(name)
  #         @obj.method(name).call(*args, **kwargs, &block)
  #       else
  #         value = self[name.to_s]
  #         case value
  #         when Array, Hash
  #           ArrayOrHashNavigationProxy.new(value)
  #         else
  #           value
  #         end
  #       end
  #     end
  #   end
  # end

  # class InvocationParams
  #   # @params : Hash

  #   # params : Hash | ArrayOrHashNavigationProxy
  #   def initialize(hashlike_params)
  #     # this doesn't seem to make any difference
  #     @params = hashlike_params.to_h
  #     # @params = hashlike_params
  #   end

  #   def [](key)
  #     @params[key]
  #   end

  #   def dig(*keys, default: nil)
  #     # keys = keys.map {|key| key.is_a?(Integer) ? key : key.to_s }
  #     @params.dig(*keys) || default
  #   end

  #   def method_missing(name, *args, **kwargs, &block)
  #     if @params.respond_to?(name)
  #       @params.method(name).call(*args, **kwargs, &block)
  #     else
  #       value = self[name]
  #       case value
  #       when Array, Hash
  #         ArrayOrHashNavigationProxy.new(value)
  #       else
  #         value
  #       end
  #     end
  #   end
  # end

  # class EnvParams < InvocationParams
  #   # params : Hash | ArrayOrHashNavigationProxy
  #   def initialize(hashlike_params = ENV)
  #     super(hashlike_params)
  #   end
  # end

  class OpsFileScript

    def self.define_for(ops_file, ruby_script)
      klass = Class.new(OpsFileScript)

      methods_defined = Set.new

      # define methods for the OpsFile's local_symbol_table: local imports and private lib directory
      ops_file.local_symbol_table.each do |symbol_name, import_reference|
        unless methods_defined.include? symbol_name
          App.instance.trace "defining method for local symbol table entry: #{symbol_name}"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.trace "resolving local symbol table entry: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_import_reference(ops_file, import_reference)
            App.instance.trace "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

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
      # App.instance.trace "sibling_symbol_table_names=#{sibling_symbol_table_names}"
      App.instance.trace "methods_defined=#{methods_defined}"
      sibling_symbol_table_names.each do |symbol_name|
        unless methods_defined.include? symbol_name
          App.instance.trace "defining method for implicit imports: #{symbol_name}"
          klass.define_method(symbol_name) do |*args, **kwargs, &block|
            App.instance.trace "resolving implicit import: #{symbol_name}"
            namespace_or_ops_file = @runtime_env.resolve_sibling_symbol(ops_file, symbol_name)
            App.instance.trace "namespace_or_ops_file=#{namespace_or_ops_file.to_s}"

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
      # - all the dynamically defined methods in the subclass of Invocation
      #
      # Return value is whatever the script returned with one exception:
      # - if the script returns a Hash or an Array, the return value is an EasyNavProxy
      invoke_method_definition = <<~INVOKE_METHOD
        def _invoke(runtime_env, hashlike_params)
          @runtime_env = runtime_env
          @params = hashlike_params.easynav
          @runtime_ops_file_path = __FILE__
          _retval = begin
            #{ruby_script}
          end
          case _retval
          when Hash, Array
            _retval.easynav
          else
            _retval
          end
        end
      INVOKE_METHOD

      invoke_method_line_count_prior_to_ruby_script_from_ops_file = 5
      klass.module_eval(invoke_method_definition, ops_file.ops_file_path.to_s, ops_file.script_line_offset - invoke_method_line_count_prior_to_ruby_script_from_ops_file)

      klass
    end


    include OpsFileScriptDSL

    attr_accessor :ops_file

    def initialize(ops_file, ruby_script)
      @ops_file = ops_file
      @script = ruby_script
      @runtime_env = nil              # this is set at the very first line of #_invoke
      @params = nil                   # this is set at the very first line of #_invoke
      @runtime_ops_file_path = nil    # this is set at the very first line of #_invoke
    end

    def backend
      @runtime_env.pty
    end

    def host_proxy_class
      @ops_file.host_proxy_class
    end

    # The _invoke method is dynamically defined as part of OpsFileScript.define_for
    def _invoke(runtime_env, hashlike_params)
      raise "Not implemented in base class."
    end

    def params(*keys, default: nil)
      keys = keys.map(&:to_s)
      if keys.empty?
        @params
      else
        @params.dig(*keys) || default
      end
    end

    def inspect
      "OpsFileScript[#{ops_file.ops_file_path}]"
    end

    def to_s
      @script
    end
  end

end
