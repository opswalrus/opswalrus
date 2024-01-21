module OpsWalrus
  ExitCodeHostTemporarilyUnavailable = 11

  class Error < StandardError
  end

  class RemoteInvocationError < Error
    def initialize(msg, deserialized_invocation_error_hash)
      super(msg)
      @hash = deserialized_invocation_error_hash
    end
  end

  class RetriableRemoteInvocationError < RemoteInvocationError
  end

  class SymbolResolutionError < Error
  end
end
