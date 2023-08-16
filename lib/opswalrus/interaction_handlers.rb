require 'sshkit'

module OpsWalrus

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
