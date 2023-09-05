require "gli"

# require_relative "walrus_lang"
require_relative "app"

module OpsWalrus
  def self.env_specified_age_ids()
    # ENV['AGE_ID'] || (ENV['OPSWALRUS_AGE_IDS'] && Dir.glob(ENV['OPSWALRUS_AGE_IDS']))
    ENV['OPSWALRUS_AGE_IDS'] && Dir.glob(ENV['OPSWALRUS_AGE_IDS'])
  end

  class Cli
    extend GLI::App

    pre do |global_options, command, options, args|
      $app = App.instance(Dir.pwd)
      $app.set_local_hostname(ENV["OPSWALRUS_LOCAL_HOSTNAME"]) if ENV["OPSWALRUS_LOCAL_HOSTNAME"]
      true
    end

    # this is invoked on an unhandled exception or a call to exit_now!
    on_error do |exception|
      next(false) if exception.is_a? GLI::CustomExit

      puts "catchall exception handler:"
      puts exception.message
      puts exception.backtrace.join("\n")
      false   # disable built-in exception handling
    end

    program_desc 'ops is an operation runner'

    desc 'Be verbose'
    switch [:v, :verbose]

    desc 'Turn on debug mode'
    switch [:d, :debug]

    switch :noop, desc: "Perform a dry run"
    switch :dryrun, desc: "Perform a dry run"
    switch :dry_run, desc: "Perform a dry run"

    flag [:h, :hosts], multiple: true, desc: "Specify the hosts.yaml file"
    flag [:t, :tags], multiple: true, desc: "Specify a set of tags to filter the hosts by"
    flag [:i, :id], multiple: true, desc: "Specify one or more Age Encryption identify files (private keys)"

    desc 'Print version'
    command :version do |c|
      c.action do |global_options, options, args|
        $app.print_version
      end
    end

    desc 'View and edit host inventory'
    long_desc 'View and edit host inventory'
    command :inventory do |c|

      desc 'List hosts in inventory'
      long_desc 'List hosts in inventory'
      c.command [:ls, :list] do |list|
        list.action do |global_options, options, args|

          hosts = global_options[:hosts]
          tags = global_options[:tags]

          log_level = global_options[:debug] && :trace || global_options[:verbose] && :debug || :info
          $app.set_log_level(log_level)

          $app.report_inventory(hosts, tags: tags)
        end
      end

      desc 'Edit hosts in inventory'
      long_desc 'Edit the hosts in the inventory and their secrets'
      # arg 'hosts_file', :optional
      c.command :edit do |edit|
        edit.action do |global_options, options, args|
          file_path = global_options[:hosts].first || HostsFile::DEFAULT_FILE_NAME

          id_files = global_options[:id]
          id_files = OpsWalrus.env_specified_age_ids if id_files.empty?
          $app.set_identity_files(id_files)

          $app.edit_inventory(file_path)
        end
      end

      desc 'Encrypt secrets in inventory file'
      long_desc 'Encrypt secrets in inventory file'
      arg 'encrypted_host_file_path', :optional
      c.command :encrypt do |encrypt|
        encrypt.action do |global_options, options, args|
          file_path = global_options[:hosts].first || HostsFile::DEFAULT_FILE_NAME
          output_file_path = args.first || file_path

          id_files = global_options[:id]
          id_files = OpsWalrus.env_specified_age_ids if id_files.empty?

          $app.set_identity_files(id_files)

          $app.encrypt_inventory(file_path, output_file_path)
        end
      end

      desc 'Decrypt secrets in inventory file'
      long_desc 'Decrypt secrets in inventory file'
      arg 'decrypted_host_file_path', :optional
      c.command :decrypt do |decrypt|
        decrypt.action do |global_options, options, args|
          file_path = global_options[:hosts].first || HostsFile::DEFAULT_FILE_NAME
          output_file_path = args.first || file_path

          id_files = global_options[:id]
          id_files = OpsWalrus.env_specified_age_ids if id_files.empty?

          $app.set_identity_files(id_files)

          $app.decrypt_inventory(file_path, output_file_path)
        end
      end

      c.default_command :list
    end

    desc 'Bootstrap a set of hosts to run opswalrus'
    long_desc 'Bootstrap a set of hotss to run opswalrus: install dependencies, ruby, opswalrus gem'
    command :bootstrap do |c|
      # dry run
      c.switch :noop, desc: "Perform a dry run"
      c.switch :dryrun, desc: "Perform a dry run"
      c.switch :dry_run, desc: "Perform a dry run"

      c.action do |global_options, options, args|
        log_level = global_options[:debug] && :trace || global_options[:verbose] && :debug || :info
        $app.set_log_level(log_level)

        hosts = global_options[:hosts]
        tags = global_options[:tags]

        $app.set_inventory_hosts(hosts)
        $app.set_inventory_tags(tags)

        id_files = global_options[:id]
        id_files = OpsWalrus.env_specified_age_ids if id_files.empty?

        $app.set_identity_files(id_files)

        dry_run = [:noop, :dryrun, :dry_run].any? {|sym| global_options[sym] || options[sym] }
        $app.dry_run! if dry_run

        $app.bootstrap()
      end
    end

    desc 'Run an operation from a package'
    long_desc 'Run the specified operation found within the specified package'
    arg 'args', :multiple
    command :run do |c|
      c.switch :pass, desc: "Prompt for a sudo password"
      c.switch :script, desc: "Script mode"

      c.flag [:u, :user], desc: "Specify the user that the operation will run as"
      c.flag [:p, :params], desc: "Either specify a file that contains JSON OR specify a JSON encoded string. In both cases, the JSON represents the runtime arguments (i.e. the params) for the operation. The JSON string must conform to the params schema for the operation being run."

      # dry run
      c.switch :noop, desc: "Perform a dry run"
      c.switch :dryrun, desc: "Perform a dry run"
      c.switch :dry_run, desc: "Perform a dry run"

      c.action do |global_options, options, args|
        log_level = global_options[:debug] && :trace || global_options[:verbose] && :debug || :info
        $app.set_log_level(log_level)

        hosts = global_options[:hosts]
        $app.set_inventory_hosts(hosts)

        tags = global_options[:tags]
        $app.set_inventory_tags(tags)

        user = options[:user]
        $app.set_sudo_user(user) if user

        params = options[:params]
        $app.set_params(params) if params

        id_files = global_options[:id]
        id_files = OpsWalrus.env_specified_age_ids if id_files.empty?

        $app.set_identity_files(id_files)

        dry_run = [:noop, :dryrun, :dry_run].any? {|sym| global_options[sym] || options[sym] }
        $app.dry_run! if dry_run

        if options[:pass]
          $app.prompt_sudo_password
        end

        if options[:script]
          $app.script_mode!
        end

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
          log_level = global_options[:debug] && :trace || global_options[:verbose] && :debug || :info
          $app.set_log_level(log_level)

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
          log_level = global_options[:debug] && :trace || global_options[:verbose] && :debug || :info
          $app.set_log_level(log_level)

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
