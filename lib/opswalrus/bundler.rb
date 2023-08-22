require 'git'
require 'set'

require_relative "package_file"
require_relative "traversable"
require_relative "zip"

module OpsWalrus
  class Bundler
    BUNDLE_DIR = "opswalrus_bundle"

    include Traversable

    attr_accessor :pwd

    def initialize(working_directory_path)
      @pwd = working_directory_path.to_pathname
      @bundle_dir = @pwd.join(BUNDLE_DIR)
    end

    def bundle_dir
      @bundle_dir
    end

    def ensure_pwd_bundle_directory_exists
      FileUtils.mkdir_p(@bundle_dir) unless @bundle_dir.exist?
    end

    # # returns the OpsFile within the bundle directory that represents the given ops_file (which is outside of the bundle directory)
    # def build_bundle_for_ops_file(ops_file)
    #   if ops_file.package_file   # ops_file is part of larger package
    #     self_pkg_dir = build_bundle_for_package(ops_file.package_file)
    #     relative_ops_file_path = ops_file.ops_file_path.relative_path_from(ops_file.package_file.dirname)
    #   else
    #     # ops_file is not part of a larger package
    #     # in this case, we want to bundle the ops_file.dirname into the bundle directory
    #     update
    #     self_pkg_dir = include_directory_in_bundle_as_self_pkg(ops_file.dirname)
    #     relative_ops_file_path = ops_file.ops_file_path.relative_path_from(ops_file.dirname)
    #   end
    #   ops_file_in_self_pkg = self_pkg_dir.join(relative_ops_file_path)
    # end

    # # we want to bundle the package represented by package_file into the bundle directory that
    # # resides within the package directory that contains the package_file
    # def build_bundle_for_package(package_file)
    #   bundler_for_package = Bundler.new(package_file.dirname)
    #   bundler_for_package.update
    #   bundler_for_package.include_directory_in_bundle_as_self_pkg(pwd)
    # end

    def update
      ensure_pwd_bundle_directory_exists

      package_yaml_files = pwd.glob("./**/package.yaml") - pwd.glob("./**/#{BUNDLE_DIR}/**/package.yaml")
      package_files_within_pwd = package_yaml_files.map {|path| PackageFile.new(path.realpath) }

      download_dependency_tree(*package_files_within_pwd)
    end

    # downloads all transitive package dependencies associated with ops_files
    # all downloaded packages are placed into @bundle_dir
    def download_dependency_tree(*ops_files_and_package_files)
      package_files = ops_files_and_package_files.map(&:package_file).compact.uniq

      package_files.each do |root_package_file|
        pre_order_traverse(root_package_file) do |package_file|
          download_package_dependencies(package_file).map do |downloaded_package_directory_path|
            package_file_path = File.join(downloaded_package_directory_path, "package.yaml")
            PackageFile.new(package_file_path)
          end
        end
      end
    end

    # returns the array of the destination directories that the packages that ops_file depend on were downloaded to
    # e.g. [dir_path1, dir_path2, dir_path3, ...]
    def download_package_dependencies(package_file)
      package_file.dependencies.map do |local_name, package_reference|
        download_package(package_file, package_reference)
      end
    end

    # returns the self_pkg directory within the bundle directory
    # def include_directory_in_bundle_as_self_pkg(dirname = pwd)
    #   ensure_pwd_bundle_directory_exists

    #   destination_package_path = @bundle_dir.join("self_pkg")

    #   # recreate the destination package path - self_pkg
    #   FileUtils.remove_dir(destination_package_path) if destination_package_path.exist?
    #   FileUtils.mkdir_p(destination_package_path)

    #   # files in dirname except for the BUNDLE_DIR
    #   files = dirname.glob("*").reject {|f| f.basename.to_s == BUNDLE_DIR }
    #   files.each do |file|
    #     FileUtils.cp_r(file, destination_package_path)
    #   end

    #   destination_package_path
    # end

    # This method downloads a package_url that is a dependency referenced in the specified package_file
    # returns the destination directory that the package was downloaded to
    def download_package(package_file, package_reference)
      ensure_pwd_bundle_directory_exists

      local_name = package_reference.local_name
      package_url = package_reference.package_uri
      version = package_reference.version

      destination_package_path = @bundle_dir.join(package_reference.import_resolution_dirname)
      FileUtils.remove_dir(destination_package_path) if destination_package_path.exist?

      download_package_contents(package_file, local_name, package_url, version, destination_package_path)
      # case
      # when package_url =~ /\.git/                               # git reference
      #   download_git_package(package_url, version, destination_package_path)
      # when package_url.start_with?("file://")                   # local path
      #   path = package_url.sub("file://", "")
      #   path = path.to_pathname
      #   package_path_to_download = if path.relative?            # relative path
      #     package_file.containing_directory.join(path)
      #   else                                                    # absolute path
      #     path.realpath
      #   end

      #   raise Error, "Package not found: #{package_path_to_download}" unless package_path_to_download.exist?
      #   FileUtils.cp_r(package_path_to_download, destination_package_path)
      # when package_url.to_pathname.exist? || package_file.containing_directory.join(package_url).exist?     # local path
      #   path = package_url.to_pathname
      #   package_path_to_download = if path.relative?            # relative path
      #     package_file.containing_directory.join(path)
      #   else                                                    # absolute path
      #     path.realpath
      #   end

      #   raise Error, "Package not found: #{package_path_to_download}" unless File.exist?(package_path_to_download)
      #   FileUtils.cp_r(package_path_to_download, destination_package_path)
      # else                                                      # git reference
      #   download_git_package(package_url, version, destination_package_path)
      # end

      destination_package_path
    end

    def download_package_contents(package_file, local_name, package_url, version, destination_package_path)
      package_path = package_url.to_pathname
      package_path = package_path.to_s.gsub(/^~/, Dir.home).to_pathname
      if package_path.absolute? && package_path.exist?                                   # absolute path reference
        return case
        when package_path.directory?
          package_path_to_download = package_path.realpath
          FileUtils.cp_r(package_path_to_download, destination_package_path)
        when package_path.file?
          raise Error, "Package reference must be a directory, not a file:: #{local_name}: #{package_path}"
        else
          raise Error, "Unknown package reference for absolute path: #{local_name}: #{package_path}"
        end
      end
      if package_path.relative?                                                          # relative path reference
        rebased_path = package_file.containing_directory.join(package_path)
        if rebased_path.exist?
          return case
          when rebased_path.directory?
            package_path_to_download = rebased_path.realpath
            FileUtils.cp_r(package_path_to_download, destination_package_path)
          when rebased_path.file?
            raise Error, "Package reference must be a directory, not a file:: #{local_name}: #{package_path}"
          else
            raise Error, "Unknown package reference for relative path: #{local_name}: #{package_path}"
          end
        end
      end

      if package_uri = Git.repo?(package_url)                                                          # git repo
        download_git_package(package_uri, version, destination_package_path)
      end
    end

    def download_git_package(package_url, version = nil, destination_package_path = nil)
      ensure_pwd_bundle_directory_exists

      destination_package_path ||= dynamic_package_path_for_git_package(package_url, version)

      return destination_package_path if destination_package_path.exist?

      if version
        ::Git.clone(package_url, destination_package_path, branch: version, config: ['submodule.recurse=true'])
      else
        ::Git.clone(package_url, destination_package_path, config: ['submodule.recurse=true'])
      end

      destination_package_path
    end

    def dynamic_package_path_for_git_package(package_url, version = nil)
      package_reference_dirname = sanitize_path(package_url)
      bundle_dir.join(package_reference_dirname)
    end

    def sanitize_path(path)
      # found this at https://apidock.com/rails/v5.2.3/ActiveStorage/Filename/sanitized
      path.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "ï¿½").strip.tr("\u{202E}%$|:;/\t\r\n\\", "-")
    end

    # returns the directory that the zip file is unzipped into
    def unzip(zip_bundle_file, output_dir = nil)
      if zip_bundle_file.to_pathname.exist?
        output_dir ||= Dir.mktmpdir.to_pathname

        # unzip the bundle into the output_dir directory
        DirZipper.unzip(zip_bundle_file, output_dir)
      end
    end
  end
end
