require 'sshkit'

module OpsWalrus

  class ScopedMappingInteractionHandler
    attr_accessor :input_mappings   # Hash[ String | Regex => String ]

    def initialize(mapping, log_level = nil)
      @log_level = log_level
      @input_mappings = mapping
    end

    # temporarily adds a sudo password mapping to the interaction handler while the given block is being evaluated
    # when the given block returns, then the temporary mapping is removed from the interaction handler
    # def with_sudo_password(password, &block)
    #   with_mapping({
    #     /\[sudo\] password for .*?:\s*/ => "#{password}\n",
    #     App::LOCAL_SUDO_PASSWORD_PROMPT => "#{password}\n",
    #     # /\s+/ => nil,     # unnecessary
    #   }, &block)
    # end

    # sudo_password : String
    def mapping_for_sudo_password(sudo_password)
      {
        /\[sudo\] password for .*?:\s*/ => "#{sudo_password}\n",
        App::LOCAL_SUDO_PASSWORD_PROMPT => "#{sudo_password}\n",
        # /\s+/ => nil,     # unnecessary
      }
    end

    # temporarily adds the specified input mapping to the interaction handler while the given block is being evaluated
    # when the given block returns, then the temporary mapping is removed from the interaction handler
    #
    # mapping : Hash[ String | Regex => String ]
    def with_mapping(mapping, sudo_password = nil)
      mapping ||= {}

      raise ArgumentError.new("mapping must be a Hash") unless mapping.is_a?(Hash)

      if sudo_password
        mapping.merge!(mapping_for_sudo_password(sudo_password))
      end

      if mapping.empty?
        yield self
      else
        yield ScopedMappingInteractionHandler.new(@input_mappings.merge(mapping), @log_level)
      end
    end

    # adds the specified input mapping to the interaction handler
    #
    # mapping : Hash[ String | Regex => String ]
    def add_mapping(mapping)
      @input_mappings.merge!(mapping)
    end

    def on_data(_command, stream_name, data, channel)
      log("Looking up response for #{stream_name} message #{data.inspect}")

      response_data = begin
        first_matching_key_value_pair = @input_mappings.find {|k, _v| k === data }
        first_matching_key_value_pair&.last
      end

      if response_data.nil?
        log("Unable to find interaction handler mapping for #{stream_name}: #{data.inspect} so no response was sent")
      else
        log("Sending #{response_data.inspect}")
        if channel.respond_to?(:send_data)  # Net SSH Channel
          channel.send_data(response_data)
        elsif channel.respond_to?(:write)   # Local IO
          channel.write(response_data)
        else
          raise "Unable to write response data to channel #{channel.inspect} - does not support '#send_data' or '#write'"
        end
      end
    end

    private

    def log(message)
      # puts message
      SSHKit.config.output.send(@log_level, message) unless @log_level.nil?
    end

  end

  class PasswdInteractionHandler
    def on_data(command, stream_name, data, channel)
      # puts data
      case data
      when '(current) UNIX password: '
        channel.send_data("old_pw\n")
      when 'Enter new UNIX password: ', 'Retype new UNIX password: '
        channel.send_data("new_pw\n")
      when 'passwd: password updated successfully'
      else
        raise "Unexpected stderr #{stderr}"
    end
    end
  end

  class SudoPasswordMapper
    def initialize(sudo_password)
      @sudo_password = sudo_password
    end

    def interaction_handler
      SSHKit::MappingInteractionHandler.new({
        /\[sudo\] password for .*?:\s*/ => "#{@sudo_password}\n",
        App::LOCAL_SUDO_PASSWORD_PROMPT => "#{@sudo_password}\n",
        # /\s+/ => nil,     # unnecessary
      }, :info)
    end
  end

  class SudoPromptInteractionHandler
    def on_data(command, stream_name, data, channel)
      # puts "0" * 80
      # puts data.inspect
      case data
      when /\[sudo\] password for/
        if channel.respond_to?(:send_data)  # Net::SSH channel
          channel.send_data("conquer\n")
        elsif channel.respond_to?(:write)   # IO
          channel.write("conquer\n")
        end
      when /\s+/
        puts 'space, do nothing'
      else
        raise "Unexpected prompt: #{data} on stream #{stream_name} and channel #{channel.inspect}"
    end
    end
  end


end
