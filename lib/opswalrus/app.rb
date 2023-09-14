require "citrus"
require "io/console"
require "json"
require "random/formatter"
require "pastel"
require "pathname"
require "semantic_logger"
require "shellwords"
require "socket"
require "stringio"
require "yaml"

require_relative "patches"

require_relative "errors"
require_relative "git"
require_relative "host"
require_relative "hosts_file"
require_relative "inventory"
require_relative "operation_runner"
require_relative "bundler"
require_relative "package_file"
require_relative "version"


module OpsWalrus
  Style = Pastel.new(enabled: $stdout.tty?)

  class App
    def self.instance(*args)
      @instance ||= new(*args)
    end

    LOCAL_SUDO_PASSWORD_PROMPT = "[ops] Enter sudo password to run sudo in local environment: "


    attr_reader :local_hostname
    attr_reader :identity_file_paths

    def initialize(pwd = Dir.pwd)
      SemanticLogger.default_level = :info
      # SemanticLogger.add_appender(file_name: 'development.log', formatter: :color)   # Log to a file, and use the colorized formatter
      SemanticLogger.add_appender(io: $stdout, formatter: :color)       # Log errors and above to standard error:
      @logger = SemanticLogger[OpsWalrus]    # Logger.new($stdout, level: Logger::INFO)
      @logger.level = :info    # , :trace or 'trace'

      # @logger.warn Style.yellow("warn"), foo: "bar", baz: {qux: "quux"}
      # @logger.info Style.yellow("info"), foo: "bar", baz: {qux: "quux"}
      # @logger.debug Style.yellow("debug"), foo: "bar", baz: {qux: "quux"}
      # @logger.trace Style.yellow("trace"), foo: "bar", baz: {qux: "quux"}

      @sudo_user = nil
      @sudo_password = nil
      @identity_file_paths = []
      @inventory_host_references = []
      @inventory_tag_selections = []
      @params = nil
      @pwd = pwd.to_pathname
      @bundler = Bundler.new(@pwd)
      @local_hostname = "localhost"
      @mode = :report     # :report | :script
      @dry_run = false
      @zip_mutex = Thread::Mutex.new
    end

    def to_s
      ""  # return empty string because we won't want anyone accidentally printing or inspecting @sudo_password
    end

    def inspect
      ""  # return empty string because we won't want anyone accidentally printing or inspecting @sudo_password
    end

    def script_mode!
      @mode = :script
    end

    def report_mode?
      @mode == :report
    end

    def script_mode?
      @mode == :script
    end

    def dry_run?
      @dry_run
    end

    def dry_run!
      @dry_run = true
    end

    def set_local_hostname(hostname)
      hostname = hostname.strip
      @local_hostname = hostname.empty? ? "localhost" : hostname
    end

    def set_identity_files(*paths)
      @identity_file_paths = paths.flatten.compact.uniq
    end

    def set_inventory_hosts(*hosts)
      hosts.flatten!.compact!
      @inventory_host_references.concat(hosts).compact!
    end

    def set_inventory_tags(*tags)
      tags.flatten!.compact!
      @inventory_tag_selections.concat(tags).compact!
    end

    def bundler
      @bundler
    end

    def bundle_dir
      @bundler.bundle_dir
    end

    # log_level = :fatal, :error, :warn, :info, :debug, :trace
    def set_log_level(log_level)
      @logger.level = log_level
    end

    def fatal(*args)
      @logger.fatal(*args)
    end
    def fatal?
      @logger.fatal?
    end

    def error(*args)
      @logger.error(*args)
    end
    def error?
      @logger.error?
    end

    def warn(*args)
      @logger.warn(*args)
    end
    alias_method :important, :warn    # warn means important
    def warn?
      @logger.warn?
    end

    def info(*args)
      @logger.info(*args)
    end
    alias_method :log, :info
    def info?
      @logger.info?
    end

    def debug(*args)
      @logger.debug(*args)
    end
    def debug?
      @logger.debug?
    end

    def trace(*args)
      @logger.trace(*args)
    end
    def trace?
      @logger.trace?
    end

    def verbose?
      info? || debug? || trace?
    end

    def set_pwd(pwd)
      @pwd = pwd.to_pathname
      @bundler = Bundler.new(@pwd)
    end

    def pwd
      @pwd || raise("No working directory specified")
    end

    def set_sudo_user(user)
      @sudo_user = user
    end

    def sudo_user
      @sudo_user || "root"
    end

    def set_sudo_password(password)
      @sudo_password = password
    end

    def prompt_sudo_password
      password = IO::console.getpass(LOCAL_SUDO_PASSWORD_PROMPT)
      set_sudo_password(password)
      nil
    end

    def sudo_password
      @sudo_password
    end

    # params is a string that specifies a file path OR it is a string representation of a JSON object: '{}' | '{"key1": ... , ...}'
    def set_params(file_path_or_json_string)
      params = if File.exist?(file_path_or_json_string)
        File.read(file_path_or_json_string)
      else
        file_path_or_json_string
      end
      json_hash = JSON.parse(params) rescue nil
      json_hash = json_hash.is_a?(Hash) ? json_hash : nil

      @params = json_hash   # @params returns a Hash or nil
    end

    def bootstrap()
      set_pwd(__FILE__.to_pathname.dirname)
      bootstrap_ops_file = OpsFile.new(self, __FILE__.to_pathname.dirname.join("bootstrap.ops"))
      op = OperationRunner.new(self, bootstrap_ops_file)
      op.run([], params_json_hash: @params)
    end

    # args is of the form ["github.com/davidkellis/my-package/sub-package1", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # if the first argument is the path to a .ops file, then treat it as a local path, and add the containing package
    #   to the load path
    # otherwise, copy the
    # returns the exit status code that the script should terminate with
    def run(package_operation_and_args)
      return 0 if package_operation_and_args.empty?

      ops_file_path, operation_kv_args, tmp_bundle_root_dir = get_entry_point_ops_file_and_args(package_operation_and_args)

      ops_file = load_entry_point_ops_file(ops_file_path, tmp_bundle_root_dir)

      debug "Running: #{ops_file.ops_file_path}"

      op = OperationRunner.new(self, ops_file)
      result = op.run(operation_kv_args, params_json_hash: @params)
      exit_status = result.exit_status

      debug "Op exit_status"
      debug exit_status

      debug "Op output"
      debug JSON.pretty_generate(result.value)

      puts JSON.pretty_generate(result.value)

      exit_status
    rescue Error => e
      puts "Error: #{e.message}"
      1
    ensure
      FileUtils.remove_entry(tmp_bundle_root_dir) if tmp_bundle_root_dir
    end

    def load_entry_point_ops_file(ops_file_path, tmp_bundle_root_dir)
      ops_file = OpsFile.new(self, ops_file_path)

      # we are running the ops file from within a temporary bundle root directory created by unzipping a zip bundle workspace
      if tmp_bundle_root_dir
        return set_pwd_and_rebase_ops_file(tmp_bundle_root_dir, ops_file)
      end

      # if the ops file is contained within a bundle directory, then that means we're probably running this command invocation
      # on a remote host, e.g. /home/linuxbrew/.linuxbrew/bin/gem exec -g opswalrus ops run --script /tmp/d20230822-18829-2j5ij2 opswalrus_bundle docker install install
      # and the corresponding entry point, e.g. /tmp/d20230822-18829-2j5ij2/opswalrus_bundle/docker/install/install.ops
      # is actually being run from a temporary zip bundle root directory
      # so we want to set the app's pwd to be the parent directory of the Bundler::BUNDLE_DIR directory, e.g. /tmp/d20230822-18829-2j5ij2
      if ops_file.ops_file_path.to_s =~ /#{Bundler::BUNDLE_DIR}/
        return set_pwd_to_parent_of_bundle_dir(ops_file)
      end

      # if the ops file is part of a package, then set the package directory as the app's pwd
      if ops_file.package_file && ops_file.package_file.dirname.to_s !~ /#{Bundler::BUNDLE_DIR}/
        return set_pwd_to_ops_file_package_directory(ops_file)
      end

      ops_file
    end

    def set_pwd_to_parent_of_bundle_dir(ops_file)
      match = /^(.*)#{Bundler::BUNDLE_DIR}.*$/.match(ops_file.ops_file_path.to_s)
      parent_directory_path = match.captures.first.to_pathname.cleanpath
      set_pwd_and_rebase_ops_file(parent_directory_path, ops_file)
    end

    # sets the App's pwd to the ops file's package directory and
    # returns a new OpsFile that points at the revised pathname when considered as relative to the package file's directory
    def set_pwd_to_ops_file_package_directory(ops_file)
      set_pwd_and_rebase_ops_file(ops_file.package_file.dirname, ops_file)
    end

    # returns a new OpsFile that points at the revised pathname when considered as relative to the new working directory
    def set_pwd_and_rebase_ops_file(new_working_directory, ops_file)
      set_pwd(new_working_directory)
      rebased_ops_file_relative_path = ops_file.ops_file_path.relative_path_from(new_working_directory)
      # note: rebased_ops_file_relative_path is a relative path that is relative to new_working_directory
      absolute_ops_file_path = new_working_directory.join(rebased_ops_file_relative_path)
      OpsFile.new(self, absolute_ops_file_path)
    end

    # package_operation_and_args can take one of the following forms:
    # - ["github.com/davidkellis/my-package", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["foo.zip", "foo/myfile.ops", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["davidkellis/my-package", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["davidkellis/my-package", "operation1"]
    # - ["my-package/operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["./my-package/operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["../../my-package/operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # - ["../../my-package/operation1"]
    #
    # returns 3-tuple of the form: [ ops_file_path, operation_kv_args, optional_tmp_bundle_root_dir ]
    # such that the third item - optional_tmp_bundle_root_dir - if present, should be deleted after the script has completed running
    def get_entry_point_ops_file_and_args(package_operation_and_args)
      package_operation_and_args = package_operation_and_args.dup
      package_or_ops_file_reference = package_operation_and_args.slice!(0, 1).first
      tmp_bundle_root_dir = nil

      case
      when Dir.exist?(package_or_ops_file_reference)
        dir = package_or_ops_file_reference
        ops_file_path, operation_kv_args = find_entry_point_ops_file_in_dir(dir, package_operation_and_args)
        [ops_file_path, operation_kv_args, tmp_bundle_root_dir]
      when File.exist?(package_or_ops_file_reference)
        first_filepath = package_or_ops_file_reference.to_pathname.realpath

        ops_file_path, operation_kv_args = case first_filepath.extname.downcase
        when ".ops"
          [first_filepath, package_operation_and_args]
        when ".zip"
          tmp_bundle_root_dir = Dir.mktmpdir.to_pathname    # this is the temporary bundle root dir

          # unzip the bundle into the temp directory
          DirZipper.unzip(first_filepath, tmp_bundle_root_dir)

          find_entry_point_ops_file_in_dir(tmp_bundle_root_dir, package_operation_and_args)
        else
          raise Error, "Unknown file type for entrypoint: #{first_filepath}"
        end

        # operation_kv_args = package_operation_and_args
        [ops_file_path, operation_kv_args, tmp_bundle_root_dir]
      when repo_url = Git.repo?(package_or_ops_file_reference)
        destination_package_path = bundler.download_git_package(repo_url)

        ops_file_path, operation_kv_args = find_entry_point_ops_file_in_dir(destination_package_path, package_operation_and_args)

        # for an original package_operation_and_args of ["github.com/davidkellis/my-package", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
        # we return: [ "#{pwd}/#{Bundler::BUNDLE_DIR}/github-com-davidkellis-my-package/operation1.ops", ["arg1:val1", "arg2:val2", "arg3:val3"] ]
        [ops_file_path, operation_kv_args, tmp_bundle_root_dir]
      else
        raise Error, "Unknown operation reference: #{package_or_ops_file_reference.inspect}"
      end
    end

    # returns pair of the form: [ ops_file_path, operation_kv_args ]
    def find_entry_point_ops_file_in_dir(base_dir, package_operation_and_args)
      ops_file_path = nil
      base_path = Pathname.new(base_dir)

      path_parts = 0
      package_operation_and_args.each do |candidate_path_arg|
        candidate_base_path = base_path.join(candidate_path_arg)
        candidate_ops_file = candidate_base_path.sub_ext(".ops")
        if candidate_ops_file.exist?
          path_parts += 1
          ops_file_path = candidate_ops_file
          break
        elsif candidate_base_path.exist?
          path_parts += 1
        else
          raise Error, "Operation not found in: #{candidate_base_path}"
        end
        base_path = candidate_base_path
      end
      operation_kv_args = package_operation_and_args.drop(path_parts)

      [ops_file_path, operation_kv_args]
    end

    def bundle_status
    end

    def bundle_update
      bundler.update
    end

    def report_inventory(host_references, tags: nil)
      selected_hosts = inventory(tags, host_references)

      selected_hosts.each do |host|
        puts host.summary(verbose?)
      end
    end

    # tag_selection is an array of strings
    def inventory(tag_selection = nil, host_references_override = nil)
      host_references = host_references_override || @inventory_host_references
      tags = @inventory_tag_selections + (tag_selection || [])
      tags.uniq!

      host_references = [HostsFile::DEFAULT_FILE_NAME] if (host_references.nil? || host_references.empty?) && File.exist?(HostsFile::DEFAULT_FILE_NAME)

      Inventory.new(host_references, tags).hosts
    end

    def edit_inventory(file_path)
      raise "File not found: #{file_path}" unless File.exist?(file_path)

      HostsFile.edit(file_path)
    end

    def encrypt_inventory(file_path, output_file_path)
      raise "File not found: #{file_path}" unless File.exist?(file_path)

      hosts_file = HostsFile.new(file_path)
      hosts_file.encrypt(output_file_path)
    end

    def decrypt_inventory(file_path, output_file_path)
      raise "File not found: #{file_path}" unless File.exist?(file_path)

      hosts_file = HostsFile.new(file_path)
      hosts_file.decrypt(output_file_path)
    end

    def print_version
      puts VERSION
    end

    def unzip(zip_bundle_file = nil, output_dir = nil)
      bundler.unzip(zip_bundle_file, output_dir)
    end

    def zip
      @zip ||= begin
        @zip_mutex.synchronize do
          tmpzip = pwd.join("tmpops.zip")
          FileUtils.rm(tmpzip) if tmpzip.exist?
          DirZipper.zip(pwd, tmpzip)
        end
      end
    end

  end
end
