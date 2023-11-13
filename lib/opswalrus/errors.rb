module OpsWalrus
  class Error < StandardError
  end

  class InvocationError < Error
  end

  class SymbolResolutionError < Error
  end
end
