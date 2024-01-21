require 'tty-exit'
require 'tty-option'

require_relative "app"

module OpsWalrus
  def self.env_specified_age_ids()
    # ENV['AGE_ID'] || (ENV['OPSWALRUS_AGE_IDS'] && Dir.glob(ENV['OPSWALRUS_AGE_IDS']))
    ENV['OPSWALRUS_AGE_IDS'] && Dir.glob(ENV['OPSWALRUS_AGE_IDS'])
  end


  class Cli2
    def self.run(argv = ARGV)
      app = App.instance(Dir.pwd)
      app.set_local_hostname(ENV["OPSWALRUS_LOCAL_HOSTNAME"]) if ENV["OPSWALRUS_LOCAL_HOSTNAME"]

      command = CliCommand.new()
      command.parse(argv)
      exit_status = command.run(app)

      TTY::Exit.exit_with(exit_status)
    end

    def initialize(app)
      @app = app
    end
  end

  class OpsCmd
    include TTY::Option

    usage do
      program "ops"

      command "run"

      desc "Run a command in a new container"

      example "Set working directory (-w)",
              "  $ dock run -w /path/to/dir/ ubuntu pwd"

      example <<~EOS
      Mount volume
        $ dock run -v `pwd`:`pwd` -w `pwd` ubuntu pwd
      EOS
    end

    # argument :image do
    #   required
    #   desc "The name of the image to use"
    # end

    # argument :command do
    #   optional
    #   desc "The command to run inside the image"
    # end

    # keyword :restart do
    #   default "no"
    #   permit %w[no on-failure always unless-stopped]
    #   desc "Restart policy to apply when a container exits"
    # end

    option :verbose do
      arity "*"
      short "-v"
      desc "Verbose mode"
    end

    # flag :detach do
    #   short "-d"
    #   long "--detach"
    #   desc "Run container in background and print container ID"
    # end

    # flag :help do
    #   short "-h"
    #   long "--help"
    #   desc "Print usage"
    # end

    # option :name do
    #   required
    #   long "--name string"
    #   desc "Assign a name to the container"
    # end

    # option :port do
    #   arity one_or_more
    #   short "-p"
    #   long "--publish list"
    #   convert :list
    #   desc "Publish a container's port(s) to the host"
    # end

    def run(app)
      if params[:help]
        print help
      elsif params.errors.any?
        puts params.errors.summary
      else
        pp params.to_h
      end
      11
    rescue => e
      app.fatal "catchall exception handler:"
      app.fatal exception.class
      app.fatal exception.message
      app.fatal exception.backtrace.join("\n")
      1
    end
  end

end
