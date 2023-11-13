module OpsWalrus
  class Error < StandardError
  end

  class RemoteInvocationError < Error
  end

  class SymbolResolutionError < Error
  end
end
