require 'digest'
require 'logger'
require 'securerandom'
require 'sshkit'

require_relative 'local_non_blocking_backend'
require_relative 'local_pty_backend'

module SSHKit
  module InteractionHandler
    class Password < String
    end
  end

  module Backend
    class Abstract
      # Returns a SSHKit::Command
      # def execute(*args)
      #   options = { verbosity: :debug, raise_on_non_zero_exit: false }.merge(args.extract_options!)
      #   create_command_and_execute(args, options).success?
      # end

      # Returns a SSHKit::Command
      def execute_cmd(*args)
        options = { verbosity: :info, strip: true, raise_on_non_zero_exit: false }.merge(args.extract_options!)
        create_command_and_execute(args, options)
      end
    end
  end

  # module Runner
  #   class Sequential < Abstract
  #     def run_backend(host, &block)
  #       backend(host, &block).run
  #     # rescue ::StandardError => e
  #     #   e2 = ExecuteError.new e
  #     #   raise e2, "Exception while executing #{host.user ? "as #{host.user}@" : "on host "}#{host}: #{e.message}"
  #     end
  #   end
  # end

  class Command
    # Initialize a new Command object
    #
    # @param  [Array] A list of arguments, the first is considered to be the
    # command name, with optional variadaric args
    # @return [Command] An un-started command object with no exit staus, and
    # nothing in stdin or stdout
    #
    def initialize(*args)
      raise ArgumentError, "Must pass arguments to Command.new" if args.empty?
      @options = default_options.merge(args.extract_options!)
      # @command = sanitize_command(args.shift)
      @command = args.shift
      @args    = args
      @options.symbolize_keys!    # @options.transform_keys!(&:to_sym)
      @stdout, @stderr, @full_stdout, @full_stderr = String.new, String.new, String.new, String.new
      @uuid = Digest::SHA1.hexdigest(SecureRandom.random_bytes(10))[0..7]
    end
  end
end
