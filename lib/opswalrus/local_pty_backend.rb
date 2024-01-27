require 'open3'
require 'pty'

module SSHKit

  module Backend

    # this backend is compatible with sudo, even without the -S flag, e.g.: sudo ...
    class LocalPty < Local

      private

      def execute_command(cmd)
        output.log_command_start(cmd.with_redaction)
        cmd.started = Time.now
        # stderr_reader, stderr_writer = IO.pipe
        # PTY.spawn(cmd.to_command, err: stderr_writer.fileno) do |stdout, stdin, pid|
        PTY.spawn(cmd.to_command) do |stdout, stdin, pid|
          stdout_thread = Thread.new do
            # debug_log = StringIO.new
            buffer = ""
            partial_buffer = ""
            while !stdout.closed?
              # debug_log.puts "!!!\nbuffer=#{buffer}|EOL|\npartial=#{partial_buffer}|EOL|"
              # puts "9" * 80
              begin
                # partial_buffer = ""
                # stdout.read_nonblock(4096, partial_buffer)
                partial_buffer = stdout.read_nonblock(4096)
                buffer << partial_buffer
                # puts "nonblocking1. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stdout(output, cmd, buffer, stdin, false)
                # puts "nonblocking2. buffer=#{buffer} partial_buffer=#{partial_buffer}"
              rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK, IO::EAGAINWaitReadable
                # puts "blocking. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stdout(output, cmd, buffer, stdin, true)
                IO.select([stdout])
                retry

              # per https://stackoverflow.com/questions/1154846/continuously-read-from-stdout-of-external-process-in-ruby
              # and https://stackoverflow.com/questions/10238298/ruby-on-linux-pty-goes-away-without-eof-raises-errnoeio
              # the PTY can raise an Errno::EIO because the child process unexpectedly goes away
              # Errno::ENOENT seems to behave like EIO
              rescue EOFError, Errno::EIO, Errno::ENOENT
                # puts "eof!"
                handle_data_for_stdout(output, cmd, buffer, stdin, true)
                stdout.close unless stdout.closed?
              rescue => e
                App.instance.error "closing PTY due to unexpected error: #{e.message}"
                handle_data_for_stdout(output, cmd, buffer, stdin, true)
                stdout.close unless stdout.closed?
                # puts e.message
                # puts e.backtrace.join("\n")
              end
            end
            # puts "end!"
            # debug_log.puts "!!!\nbuffer=#{buffer}|EOL|\npartial=#{partial_buffer}|EOL|"

            # puts "*" * 80
            # puts debug_log.string

          end
          stdout_thread.join
          _pid, status = Process.wait2(pid)
          # stderr_writer.close
          # output.log_command_data(cmd, :stderr, stderr_reader.read)
          cmd.exit_status = status.exitstatus
        ensure
          output.log_command_exit(cmd)
        end
      # ensure
      #   stderr_reader.close
      end

      # returns [complete lines, new buffer]
      def split_buffer(buffer)
        # lines = buffer.split(/(\r\n)|\r|\n/)
        lines = buffer.lines("\r\n").flat_map {|line| line.lines("\r") }.flat_map {|line| line.lines("\n") }
        buffer = lines.pop
        [lines, buffer]
      end

      # todo: we want to allow for cmd.on_stdout to invoke the interactionhandlers, but we want our interaction handler
      # to be able to indicate that a password has been emitted, and therefore should be read back and omitted from the
      # logged output because, per https://toasterlovin.com/using-the-pty-class-to-test-interactive-cli-apps-in-ruby/,
      # the behavior of a PTY is to echo back any input was typed into the pseudoterminal, which means we will need to
      # discard the input that we type in for password prompts, to ensure that the password is not logged as part
      # of the stdout that we get back as we read from stdout of the spawned process
      def handle_data_for_stdout(output, cmd, buffer, stdin, is_blocked)
        # we're blocked on reading, so let's process the buffer
        lines, buffer = split_buffer(buffer)
        lines.each do |line|
          ::OpsWalrus::App.instance.trace("line=|>#{line}<|")
          emitted_response_from_interaction_handler = cmd.on_stdout(stdin, line)
          if emitted_response_from_interaction_handler.is_a?(::SSHKit::InteractionHandler::Password)
            ::OpsWalrus::App.instance.trace("emitted password #{emitted_response_from_interaction_handler}")
          end
          output.log_command_data(cmd, :stdout, line)
        end
        if is_blocked && buffer
          ::OpsWalrus::App.instance.trace("line=|>#{buffer}<|")
          emitted_response_from_interaction_handler = cmd.on_stdout(stdin, buffer)
          if emitted_response_from_interaction_handler.is_a?(::SSHKit::InteractionHandler::Password)
            ::OpsWalrus::App.instance.trace("emitted password #{emitted_response_from_interaction_handler}")
          end
          output.log_command_data(cmd, :stdout, buffer)
          buffer = ""
        end
        buffer || ""
      end


    end
  end
end
