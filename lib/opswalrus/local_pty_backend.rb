require 'open3'
require 'pty'
require 'fileutils'

module SSHKit

  module Backend

    # this backend is compatible with sudo, even without the -S flag, e.g.: sudo ...
    class LocalPty < Local

      private

      def execute_command(cmd)
        output.log_command_start(cmd.with_redaction)
        cmd.started = Time.now
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
            # debug_log.puts "!!!\nbuffer=#{buffer}|EOL|\npartial=#{partial_buffer}|EOL|"

            # puts "*" * 80
            # puts debug_log.string

          end
          stdout_thread.join
          _pid, status = Process.wait2(pid)
          cmd.exit_status = status.exitstatus
          output.log_command_exit(cmd)
        end
      end

      # returns [complete lines, new buffer]
      def split_buffer(buffer)
        lines = buffer.split(/(\r\n)|\r|\n/)
        buffer = lines.pop
        [lines, buffer]
      end

      def handle_data_for_stdout(output, cmd, buffer, stdin, is_blocked)
        # puts "handling data for stdout: #{buffer}"

        # we're blocked on reading, so let's process the buffer
        lines, buffer = split_buffer(buffer)
        lines.each do |line|
          # puts "1" * 80
          # puts line
          cmd.on_stdout(stdin, line)
          output.log_command_data(cmd, :stdout, line)
        end
        if is_blocked && buffer
          # puts "2" * 80
          # puts buffer
          cmd.on_stdout(stdin, buffer)
          output.log_command_data(cmd, :stdout, buffer)
          buffer = ""
        end
        buffer || ""
      end


    end
  end
end
