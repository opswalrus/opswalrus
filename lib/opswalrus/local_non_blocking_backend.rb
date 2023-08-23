require 'open3'
require 'fileutils'

module SSHKit

  module Backend

    # this backend is compatible with sudo if you use the -S flag, e.g.: sudo -S ...
    class LocalNonBlocking < Local

      private

      def execute_command(cmd)
        output.log_command_start(cmd.with_redaction)
        cmd.started = Time.now
        Open3.popen3(cmd.to_command) do |stdin, stdout, stderr, wait_thr|
          stdout_thread = Thread.new do
            buffer = ""
            partial_buffer = ""
            while !stdout.closed?
              # puts "9" * 80
              begin
                stdout.read_nonblock(4096, partial_buffer)
                buffer << partial_buffer
                # puts "nonblocking1. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stdout(output, cmd, buffer, stdin, false)
                # puts "nonblocking2. buffer=#{buffer} partial_buffer=#{partial_buffer}"
              rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
                # puts "blocking. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stdout(output, cmd, buffer, stdin, true)
                IO.select([stdout])
                retry

              # per https://stackoverflow.com/questions/1154846/continuously-read-from-stdout-of-external-process-in-ruby
              # and https://stackoverflow.com/questions/10238298/ruby-on-linux-pty-goes-away-without-eof-raises-errnoeio
              # the PTY can raise an Errno::EIO because the child process unexpectedly goes away
              rescue EOFError, Errno::EIO
                # puts "eof!"
                handle_data_for_stdout(output, cmd, buffer, stdin, true)
                stdout.close
              rescue => e
                puts "closing PTY due to unexpected error: #{e.message}"
                handle_data_for_stdout(output, cmd, buffer, stdin, true)
                stdout.close
                # puts e.message
                # puts e.backtrace.join("\n")
              end
            end
            # puts "end!"
          end
          stderr_thread = Thread.new do
            buffer = ""
            partial_buffer = ""
            while !stderr.closed?
              # puts "9" * 80
              begin
                stderr.read_nonblock(4096, partial_buffer)
                buffer << partial_buffer
                # puts "nonblocking1. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stderr(output, cmd, buffer, stdin, false)
                # puts "nonblocking2. buffer=#{buffer} partial_buffer=#{partial_buffer}"
              rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
                # puts "blocking. buffer=#{buffer} partial_buffer=#{partial_buffer}"
                buffer = handle_data_for_stderr(output, cmd, buffer, stdin, true)
                IO.select([stderr])
                retry

              # per https://stackoverflow.com/questions/1154846/continuously-read-from-stdout-of-external-process-in-ruby
              # and https://stackoverflow.com/questions/10238298/ruby-on-linux-pty-goes-away-without-eof-raises-errnoeio
              # the PTY can raise an Errno::EIO because the child process unexpectedly goes away
              rescue EOFError, Errno::EIO
                # puts "eof!"
                handle_data_for_stderr(output, cmd, buffer, stdin, true)
                stderr.close
              rescue => e
                puts "closing PTY due to unexpected error: #{e.message}"
                handle_data_for_stderr(output, cmd, buffer, stdin, true)
                stderr.close
                # puts e.message
                # puts e.backtrace.join("\n")
              end
            end
            # puts "end!"
          end
          stdout_thread.join
          stderr_thread.join
          cmd.exit_status = wait_thr.value.to_i
          output.log_command_exit(cmd)
        end
      end


      # returns [complete lines, new buffer]
      def split_buffer(buffer)
        lines = buffer.split(/(\r\n)\r|\n/)
        buffer = lines.pop
        [lines, buffer]
      end

      def handle_data_for_stdout(output, cmd, buffer, stdin, is_blocked)
        # we're blocked on reading, so let's process the buffer
        lines, buffer = split_buffer(buffer)
        lines.each do |line|
          cmd.on_stdout(stdin, line)
          output.log_command_data(cmd, :stdout, line)
        end
        if is_blocked && buffer
          cmd.on_stdout(stdin, buffer)
          output.log_command_data(cmd, :stdout, buffer)
          buffer = ""
        end
        buffer || ""
      end

      def handle_data_for_stderr(output, cmd, buffer, stdin, is_blocked)
        # we're blocked on reading, so let's process the buffer
        lines, buffer = split_buffer(buffer)
        lines.each do |line|
          cmd.on_stderr(stdin, line)
          output.log_command_data(cmd, :stderr, line)
        end
        if is_blocked && buffer
          cmd.on_stderr(stdin, buffer)
          output.log_command_data(cmd, :stderr, buffer)
          buffer = ""
        end
        buffer || ""
      end
    end
  end
end
