require 'sshkit'

module OpsWalrus

  class ScopedMappingInteractionHandler
    STANDARD_SUDO_PASSWORD_PROMPT = /\[sudo\] password for .*?:\s*/

    attr_accessor :input_mappings   # Hash[ String | Regex => String ]

    # log_level is one of: :fatal, :error, :warn, :info, :debug, :trace
    def initialize(mapping, log_level = nil)
      @log_level = log_level
      @input_mappings = mapping
    end

    # sudo_password : String | Nil
    def self.mapping_for_sudo_password(sudo_password)
      password_response = sudo_password && ::SSHKit::InteractionHandler::Password.new("#{sudo_password}\n")
      {
        STANDARD_SUDO_PASSWORD_PROMPT => password_response,
      }
    end

    # sudo_password : String | Nil
    def self.mapping_for_ops_sudo_prompt(sudo_password)
      password_response = sudo_password && ::SSHKit::InteractionHandler::Password.new("#{sudo_password}\n")
      {
        App::LOCAL_SUDO_PASSWORD_PROMPT => password_response,
      }
    end

    # temporarily adds the specified input mapping to the interaction handler while the given block is being evaluated
    # when the given block returns, then the temporary mapping is removed from the interaction handler
    #
    # mapping : Hash[ String | Regex => String ] | Nil
    def with_mapping(mapping = nil, sudo_password: nil, ops_sudo_password: nil, inherit_existing_mappings: false)
      new_mapping = inherit_existing_mappings ? @input_mappings : {}

      if mapping
        raise ArgumentError.new("mapping must be a Hash") unless mapping.is_a?(Hash)
        new_mapping.merge!(mapping)
      end

      # ops_sudo_password takes precedence over sudo_password
      password_mappings = if ops_sudo_password
        ScopedMappingInteractionHandler.mapping_for_ops_sudo_prompt(ops_sudo_password).
          merge(ScopedMappingInteractionHandler.mapping_for_sudo_password(nil))
      elsif sudo_password
        ScopedMappingInteractionHandler.mapping_for_sudo_password(sudo_password).
          merge(ScopedMappingInteractionHandler.mapping_for_ops_sudo_prompt(nil))
      end
      new_mapping.merge!(password_mappings) if password_mappings

      if new_mapping.empty?
        yield self
      else
        yield ScopedMappingInteractionHandler.new(new_mapping, @log_level)
      end
    end

    # adds the specified input mapping to the interaction handler
    #
    # mapping : Hash[ String | Regex => String ]
    def add_mapping(mapping)
      @input_mappings.merge!(mapping)
    end

    # cmd, :stdout, data, stdin
    # the return value from on_data is returned to Command#call_interaction_handler which is then returned verbatim
    # to Command#on_stdout, which is then returned verbatim to the backend that called #on_stdout, and in my case
    # that is LocalPty#handle_data_for_stdout.
    # So, LocalPty#handle_data_for_stdout -> Command#on_stdout -> Command#call_interaction_handler -> ScopedMappingInteractionHandler#on_data
    # which means that if I return that a password was emitted from this method, then back in LocalPty#handle_data_for_stdout
    # I can discard the subsequent line that I read from stdout in order to read and immediately discard the password
    # that this interaction handler emits.
    #
    # This method returns the data that is emitted to the response channel as a result of having processed the output
    # from a command that the interaction handler was expecting.
    def on_data(_command, stream_name, data, response_channel)
      response_data = begin
        first_matching_key_value_pair = @input_mappings.find {|k, _v| k === data }
        first_matching_key_value_pair&.last
      end

      if response_data.nil?
        trace(Style.red("No interaction handler mapping for #{stream_name}: #{data} so no response was sent"))
      else
        debug(Style.cyan("Handling #{stream_name} message #{data}"))
        debug(Style.cyan("Sending response #{response_data}"))
        if response_channel.respond_to?(:send_data)  # Net SSH Channel
          App.instance.trace "writing: #{response_data.to_s} to Net SSH Channel"
          response_channel.send_data(response_data.to_s)
        elsif response_channel.respond_to?(:write)   # Local IO (stdin)
          App.instance.trace "writing: #{response_data.to_s} to pty stdin"
          response_channel.write(response_data.to_s)
        else
          raise "Unable to write response data to channel #{channel.inspect} - does not support '#send_data' or '#write'"
        end
      end

      response_data
    end

    private

    def trace(message)
      App.instance.trace(message)
    end

    def debug(message)
      App.instance.debug(message)
    end

  end

  # class PasswdInteractionHandler
  #   def on_data(command, stream_name, data, channel)
  #     case data
  #     when '(current) UNIX password: '
  #       channel.send_data("old_pw\n")
  #     when 'Enter new UNIX password: ', 'Retype new UNIX password: '
  #       channel.send_data("new_pw\n")
  #     when 'passwd: password updated successfully'
  #     else
  #       raise "Unexpected stderr #{stderr}"
  #   end
  #   end
  # end

  # class SudoPasswordMapper
  #   def initialize(sudo_password)
  #     @sudo_password = sudo_password
  #   end

  #   def interaction_handler
  #     SSHKit::MappingInteractionHandler.new({
  #       /\[sudo\] password for .*?:\s*/ => "#{@sudo_password}\n",
  #       App::LOCAL_SUDO_PASSWORD_PROMPT => "#{@sudo_password}\n",
  #       # /\s+/ => nil,     # unnecessary
  #     }, :info)
  #   end
  # end

  # class SudoPromptInteractionHandler
  #   def on_data(command, stream_name, data, channel)
  #     case data
  #     when /\[sudo\] password for/
  #       if channel.respond_to?(:send_data)  # Net::SSH channel
  #         channel.send_data("conquer\n")
  #       elsif channel.respond_to?(:write)   # IO
  #         channel.write("conquer\n")
  #       end
  #     when /\s+/
  #       nil
  #     else
  #       raise "Unexpected prompt: #{data} on stream #{stream_name} and channel #{channel.inspect}"
  #     end
  #   end
  # end

end
