require "citrus"
require "git"
require "io/console"
require "json"
require "random/formatter"
require "shellwords"
require "socket"
require "stringio"
require "yaml"
require "pathname"
require_relative "host"
require_relative "hosts_file"
require_relative "operation_runner"
require_relative "bundler"
require_relative "package_file"

class String
  def escape_single_quotes
    gsub("'"){"\\'"}
  end

  def to_pathname
    Pathname.new(self)
  end
end

class Pathname
  def to_pathname
    self
  end
end

module OpsWalrus
  class Error < StandardError
  end

  class App
    def self.instance(*args)
      @instance ||= new(*args)
    end

    LOCAL_SUDO_PASSWORD_PROMPT = "[ops] Enter sudo password to run sudo in local environment: "


    attr_reader :local_hostname

    def initialize(pwd = Dir.pwd)
      @verbose = false
      @sudo_user = nil
      @sudo_password = nil
      @inventory_host_references = []
      @inventory_tag_selections = []
      @params = nil
      @pwd = pwd.to_pathname
      @bundler = Bundler.new(@pwd)
      @local_hostname = "localhost"
    end

    def to_s
      ""  # return empty string because we won't want anyone accidentally printing or inspecting @sudo_password
    end

    def inspect
      ""  # return empty string because we won't want anyone accidentally printing or inspecting @sudo_password
    end

    def emit_json_output!
      @emit_json_output = true
    end

    def emit_json_output?
      @emit_json_output
    end

    def set_local_hostname(hostname)
      hostname = hostname.strip
      @local_hostname = hostname.empty? ? "localhost" : hostname
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

    def set_verbose(verbose)
      @verbose = verbose
    end

    def verbose?
      @verbose
    end

    def debug?
      @verbose == 2
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

    # params must be a string representation of a JSON object: '{}' | '{"key1": ... , ...}'
    def set_params(params)
      json_hash = JSON.parse(params) rescue nil
      json_hash = json_hash.is_a?(Hash) ? json_hash : nil

      @params = json_hash   # @params returns a Hash or nil
    end

    # args is of the form ["github.com/davidkellis/my-package/sub-package1", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
    # if the first argument is the path to a .ops file, then treat it as a local path, and add the containing package
    #   to the load path
    # otherwise, copy the
    # returns the exit status code that the script should terminate with
    def run(package_operation_and_args)
      return 0 if package_operation_and_args.empty?

      ops_file_path, operation_kv_args, tmp_dir = get_entry_point_ops_file_and_args(package_operation_and_args)
      ops_file = OpsFile.new(self, ops_file_path)

      # if the ops file is part of a package, then set the package directory as the app's pwd
      # puts "run1: #{ops_file.ops_file_path}"
      if ops_file.package_file && ops_file.package_file.dirname.to_s !~ /#{Bundler::BUNDLE_DIR}/
        # puts "set pwd: #{ops_file.package_file.dirname}"
        set_pwd(ops_file.package_file.dirname)
        rebased_ops_file_relative_path = ops_file.ops_file_path.relative_path_from(ops_file.package_file.dirname)
        # note: rebased_ops_file_relative_path is a relative path that is relative to ops_file.package_file.dirname
        # puts "rebased path: #{rebased_ops_file_relative_path}"
        absolute_ops_file_path = ops_file.package_file.dirname.join(rebased_ops_file_relative_path)
        # puts "absolute path: #{absolute_ops_file_path}"
        ops_file = OpsFile.new(self, absolute_ops_file_path)
      end
      # puts "run2: #{ops_file.ops_file_path}"

      op = OperationRunner.new(self, ops_file)
      # if op.requires_sudo?
      #   prompt_sudo_password unless sudo_password
      # end
      # exit_status, out, err, script_output_structure = op.run(operation_kv_args, params_json_hash: @params, verbose: @verbose)
      result = op.run(operation_kv_args, params_json_hash: @params, verbose: @verbose)
      exit_status = result.exit_status

      if @verbose
        puts "Op exit_status"
        puts exit_status

        # puts "Op stdout"
        # puts out

        # puts "Op stderr"
        # puts err

        puts "Op output"
        # puts script_output_structure ? JSON.pretty_generate(script_output_structure) : nil.inspect
        puts JSON.pretty_generate(result.value)
      end

      if emit_json_output?
        puts JSON.pretty_generate(result.value)
      end

      exit_status
    ensure
      FileUtils.remove_entry(tmp_dir) if tmp_dir
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
    # returns 3-tuple of the form: [ ops_file_path, operation_kv_args, optional_tmp_dir ]
    # such that the third item - optional_tmp_dir - if present, should be deleted after the script has completed running
    def get_entry_point_ops_file_and_args(package_operation_and_args)
      package_operation_and_args = package_operation_and_args.dup
      package_or_ops_file_reference = package_operation_and_args.slice!(0, 1).first
      tmp_dir = nil

      case
      when Dir.exist?(package_or_ops_file_reference)
        dir = package_or_ops_file_reference
        ops_file_path, operation_kv_args = find_entry_point_ops_file_in_dir(dir, package_operation_and_args)
        [ops_file_path, operation_kv_args, tmp_dir]
      when File.exist?(package_or_ops_file_reference)
        first_filepath = package_or_ops_file_reference.to_pathname.realpath

        ops_file_path, operation_kv_args = case first_filepath.extname.downcase
        when ".ops"
          [first_filepath, package_operation_and_args]
        when ".zip"
          tmp_dir = Dir.mktmpdir.to_pathname    # this is the temporary bundle root dir

          # unzip the bundle into the temp directory
          DirZipper.unzip(first_filepath, tmp_dir)

          find_entry_point_ops_file_in_dir(tmp_dir, package_operation_and_args)
        else
          raise Error, "Unknown file type for entrypoint: #{first_filepath}"
        end

        # operation_kv_args = package_operation_and_args
        [ops_file_path, operation_kv_args, tmp_dir]
      when repo_url = git_repo?(package_or_ops_file_reference)
        destination_package_path = bundler.download_git_package(repo_url)

        ops_file_path, operation_kv_args = find_entry_point_ops_file_in_dir(destination_package_path, package_operation_and_args)

        # ops_file_path = nil
        # base_path = Pathname.new(destination_package_path)
        # path_parts = 0
        # package_operation_and_args.each do |candidate_path_arg|
        #   candidate_base_path = base_path.join(candidate_path_arg)
        #   candidate_ops_file = candidate_base_path.sub_ext(".ops")
        #   if candidate_ops_file.exist?
        #     path_parts += 1
        #     ops_file_path = candidate_ops_file
        #     break
        #   elsif candidate_base_path.exist?
        #     path_parts += 1
        #   else
        #     raise Error, "Operation not found in #{repo_url}: #{candidate_base_path}"
        #   end
        #   base_path = candidate_base_path
        # end
        # operation_kv_args = package_operation_and_args.drop(path_parts)

        # for an original package_operation_and_args of ["github.com/davidkellis/my-package", "operation1", "arg1:val1", "arg2:val2", "arg3:val3"]
        # we return: [ "#{pwd}/#{Bundler::BUNDLE_DIR}/github-com-davidkellis-my-package/operation1.ops", ["arg1:val1", "arg2:val2", "arg3:val3"] ]
        [ops_file_path, operation_kv_args, tmp_dir]
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

    # git_repo?("davidkellis/arborist") -> "https://github.com/davidkellis/arborist"
    # returns the repo URL
    def git_repo?(repo_reference)
      candidate_repo_references = [
        repo_reference,
        repo_reference =~ /(\.(com|net|org|dev|io|local))\// && "https://#{repo_reference}",
        repo_reference !~ /github\.com\// && repo_reference =~ /^[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}\/([\w\.@\:\-~]+)$/i && "https://github.com/#{repo_reference}"    # this regex is from https://www.npmjs.com/package/github-username-regex and https://www.debuggex.com/r/H4kRw1G0YPyBFjfm
      ].compact
      working_repo_reference = candidate_repo_references.find {|reference| Git.ls_remote(reference) rescue nil }
      working_repo_reference
    end

    # def is_dir_git_repo?(dir_path)
    #   Git.ls_remote(reference) rescue nil
    # end

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

      host_references = ["hosts.yml"] if (host_references.nil? || host_references.empty?) && File.exist?("hosts.yml")

      hosts_files, host_strings = host_references.partition {|ref| File.exist?(ref) }
      hosts_files = hosts_files.map {|file_path| HostsFile.new(file_path) }
      untagged_hosts = host_strings.map(&:strip).uniq.map {|host| Host.new(host) }
      inventory_file_hosts = hosts_files.reduce({}) do |host_map, hosts_file|
        hosts_file.hosts.each do |host|
          (host_map[host] ||= host).tag!(host.tags)
        end

        host_map
      end.keys
      all_hosts = untagged_hosts + inventory_file_hosts

      selected_hosts = if tags.empty?
        all_hosts
      else
        all_hosts.select do |host|
          tags.all? {|t| host.tags.include? t }
        end
      end

      selected_hosts.sort_by(&:to_s)
    end

    def unzip(zip_bundle_file = nil, output_dir = nil)
      bundler.unzip(zip_bundle_file, output_dir)
    end

    def zip
      tmpzip = pwd.join("tmpops.zip")
      FileUtils.rm(tmpzip) if tmpzip.exist?
      @zip_bundle_path ||= DirZipper.zip(pwd, tmpzip)
    end

  end
end
