module OpsWalrus
  class Error < StandardError
  end

  class RemoteInvocationError < Error
    def initialize(msg, deserialized_invocation_error_hash)
      super(msg)
      @hash = deserialized_invocation_error_hash
    end
  end

  class SymbolResolutionError < Error
  end
end
