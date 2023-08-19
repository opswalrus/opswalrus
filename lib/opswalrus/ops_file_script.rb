require_relative 'host'
require_relative 'invocation'

module OpsWalrus

  # todo: we can get rid of this
  class OpsFileScript
    attr_accessor :ops_file

    def initialize(ops_file, ruby_script)
      @ops_file = ops_file
      @ruby_script = ruby_script
      @invocation_class = Invocation.define_invocation_class(ops_file)
      @host_proxy_class = HostProxy.define_host_proxy_class(ops_file)
    end

    def host_proxy_class
      @host_proxy_class
    end

    def script
      @ruby_script
    end

    def invoke(runtime_env, params_hash)
      @invocation_class.new(self, runtime_env, params_hash).evaluate
    end

    def to_s
      @ruby_script
    end
  end

end
