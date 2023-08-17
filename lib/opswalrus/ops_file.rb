require 'pathname'
require 'yaml'
require_relative 'git'
require_relative 'ops_file_script'

module OpsWalrus

  class OpsFile
    attr_accessor :app
    attr_accessor :ops_file_path
    attr_accessor :yaml
    attr_accessor :script

    def initialize(app, ops_file_path)
      @app = app
      @ops_file_path = ops_file_path.to_pathname.expand_path
    end

    def hash
      @ops_file_path.hash
    end

    def eql?(other)
      self.class == other.class && self.hash == other.hash
    end

    def yaml
      @yaml || (load_file && @yaml)
    end

    def script_line_offset
      @script_line_offset || (load_file && @script_line_offset)
    end

    def script
      @script || (load_file && @script)
    end

    def load_file
      yaml, ruby_script = if @ops_file_path.exist?
        parse(File.read(@ops_file_path))
      end || ["", ""]
      @script_line_offset = yaml.lines.size + 1   # +1 to account for the ... line
      @yaml = YAML.load(yaml) || {}     # post_invariant: @yaml is a Hash
      @script = OpsFileScript.new(self, ruby_script)
    end

    def parse(script_string)
      file_halves = script_string.split(/^\.\.\.$/, 2)
      case file_halves.count
      when 1
        yaml, ruby_script = "", file_halves
      when 2
        yaml, ruby_script = *file_halves
      else
        raise Error, "Unexpected number of file sections: #{file_halves.inspect}"
      end
      [yaml, ruby_script]
    end

    def params
      yaml["params"]
    end

    def output
      yaml["output"]
    end

    def package_file
      return @package_file if @package_file_evaluated
      @package_file ||= begin
        ops_file_path = @ops_file_path.realpath
        ops_file_path.ascend.each do |path|
          candidate_package_file_path = path.join("package.yaml")
          return PackageFile.new(candidate_package_file_path) if candidate_package_file_path.exist?
        end
        nil
      end
      @package_file_evaluated = true
      @package_file
    end

    # returns a map of the form: {"local_symbol" => import_reference, ... }
    # import_reference is one of:
    # 1. a package reference that matches one of the local package names in the dependencies captured in packages.yaml
    # 2. a package reference that resolves to a relative path pointing at a package directory
    # 3. a path that resolves to a directory containing ops files
    # 4. a path that resolves to an ops file
    def imports
      @imports ||= begin
        imports_hash = yaml["imports"] || {}
        imports_hash.map do |local_name, yaml_import_reference|
          local_name = local_name.to_s
          import_reference = case yaml_import_reference

          # when the imports line says:
          # imports:
          #   my_package: my_package
          in String => import_str
            case
            when package_reference = package_file&.dependency(import_str)     # package dependency reference
              # in this context, import_str is the local package name documented in the package's dependencies
              PackageDependencyReference.new(local_name, package_reference)
            when import_str.to_pathname.exist?                                # path reference
              path = import_str.to_pathname
              case
              when path.directory?
                DirectoryReference.new(local_name, path.realpath)
              when path.file? && path.extname.downcase == ".ops"
                OpsFileReference.new(local_name, path.realpath)
              else
                raise Error, "Unknown import reference: #{local_name} -> #{import_str.inspect}"
              end
            when Git.repo?(import_str)                                        # ops file has imported an ad-hoc git repo
              package_uri = import_str
              destination_package_path = app.bundler.dynamic_package_path_for_git_package(package_uri)
              # puts "DynamicPackageImportReference: #{local_name} -> #{destination_package_path}"
              DynamicPackageImportReference.new(local_name, DynamicPackageReference.new(local_name, package_uri, nil))
            else
              raise Error, "Unknown import reference: #{local_name}: #{yaml_import_reference.inspect}"
            end

          # when the imports line says:
          # imports:
          #   my_package:
          #     url: https://...
          #     version: 2.1
          # in Hash => package_defn
          #   url = package_defn["url"]
          #   version = package_defn["version"]
          #   PackageReference.new(local_name, url, version&.to_s)
          else
            raise Error, "Unknown import reference: #{local_name}: #{yaml_import_reference.inspect}"
          end
          [local_name, import_reference]
        end.to_h
      end
    end

    def invoke(runtime_env, params_hash)
      # puts "invoking: #{ops_file_path}"
      script.invoke(runtime_env, params_hash)
    end

    def build_params_hash(*args, **kwargs)
      params_hash = {}

      # if there is only one Hash object in args, treat that as the params hash
      if args.size == 1 && args.first.is_a?(Hash)
        tmp_params_hash = args.first.transform_keys(&:to_s)
        params_hash.merge!(tmp_params_hash)
      end

      # if there are the same number of args as there are params, then treat each one as the corresponding param
      if args.size == params.keys.size
        tmp_params_hash = params.keys.zip(args).to_h.transform_keys(&:to_s)
        params_hash.merge!(tmp_params_hash)
      end

      # merge in the kwargs as part of the params hash
      params_hash.merge!(kwargs.transform_keys(&:to_s))

      params_hash
    end

    # symbol table derived from explicit imports and the import for the private lib directory if it exists
    # map of: "symbol_name" => ImportReference
    def local_symbol_table
      @local_symbol_table ||= begin
        local_symbol_table = {}

        local_symbol_table.merge!(imports)

        # this is the import for the private lib directory if it exists
        if private_lib_dir.exist?
          local_symbol_table[basename.to_s] = DirectoryReference.new(basename.to_s, private_lib_dir)
        end

        local_symbol_table
      end
    end

    def resolve_import(symbol_name)
      local_symbol_table[symbol_name]
    end

    # def namespace
    #   @namespace ||= begin
    #     ns = Namespace.new
    #     sibling_ops_files.each do |ops_file|
    #       ns.add(ops_file.basename, ops_file)
    #     end
    #     sibling_directories.each do |dir_path|
    #       dir_basename = dir_path.basename
    #       ns.add(dir_basename, ) unless resolve_symbol.resolve_symbol(dir_basename)
    #     end
    #     ns
    #   end
    # end

    # "/home/david/sync/projects/ops/ops/core/host/info.ops" => "/home/david/sync/projects/ops/ops/core/host"
    def dirname
      @ops_file_path.dirname
    end

    # "/home/david/sync/projects/ops/ops/core/host/info.ops" => "info"
    def basename
      @ops_file_path.basename(".ops")
    end

    # "/home/david/sync/projects/ops/ops/core/host/info.ops" => "/home/david/sync/projects/ops/ops/core/host/info"
    def private_lib_dir
      dirname.join(basename)
    end

    def sibling_ops_files
      dirname.glob("*.ops").map {|path| OpsFile.new(app, path) }
    end

    # irb(main):073:0> OpsFile.new("/home/david/sync/projects/ops/example/davidinfra/test.ops").sibling_directories
    # => [#<Pathname:/home/david/sync/projects/ops/example/davidinfra/caddy>, #<Pathname:/home/david/sync/projects/ops/example/davidinfra/prepare_host>, #<Pathname:/home/david/sync/projects/ops/example/davidinfra/roles>]
    def sibling_directories
      dirname.glob("*").select(&:directory?)
    end

  end
end
