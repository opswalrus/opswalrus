require "gli"

# require_relative "walrus_lang"
require_relative "app"

module OpsWalrus
  class Cli
    extend GLI::App

    pre do |global_options, command, options, args|
      $app = App.instance(Dir.pwd)
      $app.set_local_hostname(ENV["WALRUS_LOCAL_HOSTNAME"]) if ENV["WALRUS_LOCAL_HOSTNAME"]
      true
    end

    # this is invoked on an unhandled exception or a call to exit_now!
    on_error do |exception|
      # puts "*" * 80
      # puts "catchall exception handler:"
      # puts exception.message
      # puts exception.backtrace.join("\n")
      false   # disable built-in exception handling
    end

    program_desc 'ops is an operation runner'

    desc 'Be verbose'
    switch [:v, :verbose]

    desc 'Debug'
    switch [:d, :debug]

    flag [:h, :hosts], multiple: true, desc: "Specify the hosts.yaml file"
    flag [:t, :tags], multiple: true, desc: "Specify a set of tags to filter the hosts by"

    desc 'Report on the host inventory'
    long_desc 'Report on the host inventory'
    command :inventory do |c|
      c.action do |global_options, options, args|
        hosts = global_options[:hosts]
        tags = global_options[:tags]

        $app.set_verbose(global_options[:debug] || global_options[:verbose])

        $app.report_inventory(hosts, tags: tags)
      end
    end

    desc 'Run an operation from a package'
    long_desc 'Run the specified operation found within the specified package'
    arg_name 'args', :multiple
    command :run do |c|
      c.flag [:u, :user], desc: "Specify the user that the operation will run as"
      c.switch :pass, desc: "Prompt for a sudo password"
      c.flag [:p, :params], desc: "JSON string that represents the input parameters for the operation. The JSON string must conform to the params schema for the operation."
      c.switch :json, desc: "Emit JSON output"

      c.action do |global_options, options, args|
        hosts = global_options[:hosts] || []
        tags = global_options[:tags] || []

        $app.set_inventory_hosts(hosts)
        $app.set_inventory_tags(tags)

        verbose = case
        when global_options[:debug]
          2
        when global_options[:verbose]
          1
        end

        user = options[:user]
        params = options[:params]

        $app.set_verbose(verbose)
        $app.set_params(params)

        $app.set_sudo_user(user) if user

        if options[:pass]
          $app.prompt_sudo_password
        end

        if options[:json]
          $app.emit_json_output!
        end

        # puts "verbose"
        # puts verbose.inspect
        # puts "user"
        # puts user.inspect
        # puts "args"
        # puts args.inspect

        exit_status = $app.run(args)

        exit_now!("error", exit_status) unless exit_status == 0
      end
    end

    desc 'Bundle dependencies'
    long_desc 'Download and bundle the dependencies for the operations found in the current directory'
    command :bundle do |c|

      desc 'Update bundle dependencies'
      long_desc 'Download and bundle the latest versions of dependencies for the current package'
      c.command :update do |update|
        update.action do |global_options, options, args|
          $app.bundle_update
        end
      end

      desc 'List bundle dependencies'
      long_desc 'List bundle dependencies'
      c.command :status do |status|
        status.action do |global_options, options, args|
          $app.bundle_status
        end
      end

      desc 'Unzip bundle'
      long_desc 'Unzip the specified bundle zip file to the specified directory'
      c.command :unzip do |unzip|
        unzip.flag [:o, :output], desc: "Specify the output directory"

        unzip.action do |global_options, options, args|
          output_dir = options[:output]
          zip_file_path = args.first

          destination_dir = $app.unzip(zip_file_path, output_dir)

          if destination_dir
            puts destination_dir
          end
        end
      end

      c.default_command :status
    end

  end
end

def main
  exit_status = OpsWalrus::Cli.run(ARGV)
  exit exit_status
end

main if __FILE__ == $0
