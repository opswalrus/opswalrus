require 'pathname'
require 'yaml'

require_relative 'bundler'

module OpsWalrus

  # these are static package references defined ahead of time in the package file
  class PackageReference
    attr_accessor :local_name
    attr_accessor :package_uri
    attr_accessor :version

    def initialize(local_name, package_uri, version = nil)
      @local_name, @package_uri, @version = local_name, package_uri, version
    end

    def sanitized_package_uri
      sanitize_path(@package_uri)
    end

    def sanitize_path(path)
      # found this at https://apidock.com/rails/v5.2.3/ActiveStorage/Filename/sanitized
      path.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "ï¿½").strip.tr("\u{202E}%$|:;/\t\r\n\\", "-")
    end

    # important: the import_resolution_dirname implemented as the local_name is critical because Bundler#download_package downloads
    # package dependencies to the name that this method returns, which must match the package reference's local name
    # so that later, when the package is being looked up on the load path (in LoadPath#resolve_import_reference),
    # the package reference's referenced git repo or file path may not exist or be available, and so the package
    # reference's local_name is used to look up the name of the directory that the bundled dependency resides at, and so
    # the package reference's local_name must be the name of the directory that the dependency is placed in within the bundle_dir.
    # If this implementation changes, then Bundler#download_package and LoadPath#resolve_import_reference must also
    # change in order for the three things to reconcile with respect to one another, since all three bits of logic are
    # what make bundling package dependencies and loading them function properly.
    def import_resolution_dirname
      local_name
    end

    def to_s
      "PackageReference(local_name=#{@local_name}, package_uri=#{@package_uri}, version=#{@version})"
    end

    def summary
      if version
        "#{package_uri}:#{version}"
      else
        package_uri
      end
    end
  end

  # these are dynamic package references defined at runtime when an OpsFile's imports are being evaluated.
  # this will usually be the case when an ops file does not belong to a package
  class DynamicPackageReference < PackageReference
    def import_resolution_dirname
      sanitized_package_uri
    end
  end

  class PackageFile
    attr_accessor :package_file_path
    attr_accessor :yaml

    def initialize(package_file_path)
      @package_file_path = package_file_path.to_pathname.expand_path
      @yaml = YAML.load(File.read(package_file_path)) if @package_file_path.exist?
      @yaml ||= {}
    end

    def package_file
      self
    end

    def bundle!
      bundler_for_package = Bundler.new(dirname)
      bundler_for_package.update
    end

    def dirname
      @package_file_path.dirname
    end

    def hash
      @package_file_path.hash
    end

    def eql?(other)
      self.class == other.class && self.hash == other.hash
    end

    def containing_directory
      Pathname.new(@package_file_path).parent
    end

    # returns a map of the form: {"local_package_name" => PackageReference1, ... }
    def dependencies
      @dependencies ||= begin
        dependencies_hash = yaml["dependencies"] || {}
        dependencies_hash.map do |local_name, package_defn|
          package_reference = case package_defn
          in String => package_url
            PackageReference.new(local_name, package_url)
          in Hash
            url = package_defn["url"]
            version = package_defn["version"]
            PackageReference.new(local_name, url, version&.to_s)
          else
            raise Error, "Unknown package reference in #{package_file_path}:\n  #{local_name}: #{package_defn.inspect}"
          end
          [local_name, package_reference]
        end.to_h
      end
    end

    # returns a PackageReference
    def dependency(local_package_name)
      dependencies[local_package_name]
    end
  end

end
