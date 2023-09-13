require 'json'
require 'shellwords'
require 'socket'
require 'sshkit'

require_relative 'interaction_handlers'
require_relative 'traversable'
require_relative 'walrus_lang'

module OpsWalrus

  class ImportReference
    attr_accessor :local_name

    def initialize(local_name)
      @local_name = local_name
    end
  end

  class PackageDependencyReference < ImportReference
    attr_accessor :package_reference
    def initialize(local_name, package_reference)
      super(local_name)
      @package_reference = package_reference
    end
    def to_s
      "PackageDependencyReference(local_name=#{@local_name}, package_reference=#{@package_reference})"
    end
    def summary
      "#{local_name}: #{package_reference.summary}"
    end
  end

  class DirectoryReference < ImportReference
    attr_accessor :dirname
    def initialize(local_name, dirname)
      super(local_name)
      @dirname = dirname
    end
    def to_s
      "DirectoryReference(local_name=#{@local_name}, dirname=#{@dirname})"
    end
    def summary
      "#{local_name}: #{dirname}"
    end
  end

  class DynamicPackageImportReference < ImportReference
    attr_accessor :package_reference
    def initialize(local_name, package_reference)
      super(local_name)
      @package_reference = package_reference
    end
    def to_s
      "DynamicPackageImportReference(local_name=#{@local_name}, package_reference=#{@package_reference})"
    end
    def summary
      "#{local_name}: #{package_reference.summary}"
    end
  end

  class OpsFileReference < ImportReference
    attr_accessor :ops_file_path
    def initialize(local_name, ops_file_path)
      super(local_name)
      @ops_file_path = ops_file_path
    end
    def to_s
      "DirectoryReference(local_name=#{@local_name}, ops_file_path=#{@ops_file_path})"
    end
    def summary
      "#{local_name}: #{ops_file_path}"
    end
  end

  # Namespace is really just a Map of symbol_name -> (Namespace | OpsFile) pairs
  class Namespace
    attr_accessor :runtime_env
    attr_accessor :dirname
    attr_accessor :symbol_table

    # dirname is an absolute path
    def initialize(runtime_env, dirname)
      @runtime_env = runtime_env
      @dirname = dirname
      @symbol_table = {}    # "symbol_name" => ops_file_or_child_namespace
    end

    def to_s(indent = 0)
      str = "Namespace: #{@dirname.to_s}\n"
      @symbol_table.each do |k, v|
        if v.is_a? Namespace
          str << "#{'  ' * (indent)}|- #{k} : #{v.to_s(indent + 1)}"
        else
          str << "#{'  ' * (indent)}|- #{k} : #{v.to_s}\n"
        end
      end
      str
    end

    def add(symbol_name, ops_file_or_child_namespace)
      @symbol_table[symbol_name.to_s] = ops_file_or_child_namespace
    end

    def resolve_symbol(symbol_name)
      @symbol_table[symbol_name.to_s]
    end

  end

  # the assumption is that we have a bundle directory with all the packages in it
  # and the bundle directory is the root directory
  class LoadPath
    include Traversable

    attr_accessor :dir
    attr_accessor :runtime_env

    def initialize(runtime_env, dir)
      @runtime_env = runtime_env
      @dir = dir
      @root_namespace = build_symbol_resolution_tree(@dir)
      @path_map = build_path_map(@root_namespace)

      App.instance.trace "LoadPath for #{@dir} ************************************************************"
      App.instance.trace 'root namespace ******************************************************************'
      App.instance.trace @root_namespace.to_s
      App.instance.trace 'path map ************************************************************************'
      @path_map.each do |k,v|
        App.instance.trace "#{k.to_s}: #{v.to_s}"
      end

      @dynamic_package_additions_memo = {}
    end

    # returns a tree of Namespace -> {Namespace* -> {Namespace* -> ..., OpsFile*}, OpsFile*}
    def build_symbol_resolution_tree(directory_path)
      namespace = Namespace.new(runtime_env, directory_path)

      directory_path.glob("*.ops").each do |ops_file_path|
        ops_file = OpsFile.new(@app, ops_file_path)
        namespace.add(ops_file.basename, ops_file)
      end

      directory_path.glob("*").
                     select(&:directory?).
                     reject {|dir| dir.basename.to_s.downcase == Bundler::BUNDLE_DIR }.
                     each do |dir_path|
        dir_basename = dir_path.basename
        unless namespace.resolve_symbol(dir_basename)
          child_namespace = build_symbol_resolution_tree(dir_path)
          namespace.add(dir_basename, child_namespace)
        end
      end

      namespace
    end

    # returns a Map of path -> (Namespace | OpsFile) pairs
    def build_path_map(root_namespace)
      path_map = {}

      pre_order_traverse(root_namespace) do |namespace_or_ops_file|
        case namespace_or_ops_file
        when Namespace
          path_map[namespace_or_ops_file.dirname] = namespace_or_ops_file
        when OpsFile
          path_map[namespace_or_ops_file.ops_file_path] = namespace_or_ops_file
        end

        namespace_or_ops_file.symbol_table.values if namespace_or_ops_file.is_a?(Namespace)
      end

      path_map
    end

    def includes_path?(path)
      !!@path_map[path]
    end

    def dynamically_add_new_package_dir(new_package_dir)
      # patch the symbol resolution (namespace) tree
      dir_basename = new_package_dir.basename
      unless @root_namespace.resolve_symbol(dir_basename)
        new_child_namespace = build_symbol_resolution_tree(new_package_dir)
        @root_namespace.add(dir_basename, new_child_namespace)

        # patch the path map
        new_partial_path_map = build_path_map(new_child_namespace)
        @path_map.merge!(new_partial_path_map)
      end
    end

    # returns a Namespace
    def lookup_namespace(ops_file)
      @path_map[ops_file.dirname]
    end

    # returns a Namespace or OpsFile
    def resolve_symbol(origin_ops_file, symbol_name)
      resolved_namespace_or_ops_file = lookup_namespace(origin_ops_file)&.resolve_symbol(symbol_name)
      App.instance.debug("LoadPath#resolve_symbol(#{origin_ops_file}, #{symbol_name}) -> #{resolved_namespace_or_ops_file}")
      resolved_namespace_or_ops_file
    end

    # returns a Namespace | OpsFile
    def resolve_import_reference(origin_ops_file, import_reference)
      resolved_namespace_or_ops_file = case import_reference
      when PackageDependencyReference
        # App.instance.trace "root namespace: #{@root_namespace.symbol_table}"
        @root_namespace.resolve_symbol(import_reference.package_reference.import_resolution_dirname)   # returns the Namespace associated with the bundled package import_resolution_dirname (i.e. the local name)
      when DynamicPackageImportReference
        dynamic_package_reference = import_reference.package_reference
        @dynamic_package_additions_memo[dynamic_package_reference] ||= begin
          # App.instance.trace "Downloading dynamic package: #{dynamic_package_reference.inspect}"
          App.instance.debug("Downloading dynamic package: #{dynamic_package_reference}")
          dynamically_added_package_dir = @runtime_env.app.bundler.download_git_package(dynamic_package_reference.package_uri, dynamic_package_reference.version)
          dynamically_add_new_package_dir(dynamically_added_package_dir)
          dynamically_added_package_dir
        end
        @root_namespace.resolve_symbol(import_reference.package_reference.import_resolution_dirname)   # returns the Namespace associated with the bundled package dirname (i.e. the sanitized package uri)
      when DirectoryReference
        @path_map[import_reference.dirname]
      when OpsFileReference
        @path_map[import_reference.ops_file_path]
      end
      App.instance.debug("LoadPath#resolve_import_reference(#{origin_ops_file}, #{import_reference}) -> #{resolved_namespace_or_ops_file}")
      resolved_namespace_or_ops_file
    end
  end

  class RuntimeEnvironment
    include Traversable

    attr_accessor :app
    attr_accessor :pty
    attr_reader :env

    def initialize(app)
      @app = app
      @env = EnvParams.new(ENV)
      @bundle_load_path = LoadPath.new(self, @app.bundle_dir)
      @app_load_path = LoadPath.new(self, @app.pwd)

      # we include this sudo password mapping by default because if a bundled script is being run on a remote host,
      # then the remote command invocation will include the --pass flag when being run on the remote host, which will
      # interactively prompt for a sudo password, and that will be the only opportunity for the command host
      # that is running the bundled script on the remote host to interactively enter a sudo password for the remote context
      # since the remote ops command will be running within a PTY, and the interactive prompts running on the remote
      # host will be managed by the local ScopedMappingInteractionHandler running within the instance of the ops command
      # process on the remote host, and the command host will not have any further opportunity to interactively enter
      # any prompts on the remote host
      interaction_handler_mapping_for_sudo_password = ScopedMappingInteractionHandler.mapping_for_sudo_password(sudo_password)
      @interaction_handler = ScopedMappingInteractionHandler.new(interaction_handler_mapping_for_sudo_password)

      configure_sshkit
    end

    # input_mapping : Hash[ String | Regex => String ]
    # sudo_password : String
    def handle_input(input_mapping, sudo_password: nil, ops_sudo_password: nil, inherit_existing_mappings: true, &block)
      @interaction_handler.with_mapping(
        input_mapping,
        sudo_password: sudo_password,
        ops_sudo_password: ops_sudo_password,
        inherit_existing_mappings: inherit_existing_mappings,
        &block
      )
    end

    # configure sshkit globally
    def configure_sshkit
      SSHKit.config.use_format :blackhole
      SSHKit.config.output_verbosity = :info

      if app.debug? || app.trace?
        SSHKit.config.use_format :pretty
        SSHKit.config.output_verbosity = :debug
      end

      SSHKit::Backend::Netssh.configure do |ssh|
        ssh.pty = true                # necessary for interaction with sudo on the remote host
        ssh.connection_timeout = 60   # seconds
        ssh.ssh_options = {           # this hash is passed in as the options hash (3rd argument) to Net::SSH.start(host, user, options) - see https://net-ssh.github.io/net-ssh/Net/SSH.html
          auth_methods: %w(publickey password),   # :auth_methods => an array of authentication methods to try
                                                  # :forward_agent => set to true if you want the SSH agent connection to be forwarded
                                                  # :keepalive => set to true to send a keepalive packet to the SSH server when there's no traffic between the SSH server and Net::SSH client for the keepalive_interval seconds. Defaults to false.
                                                  # :keepalive_interval => the interval seconds for keepalive. Defaults to 300 seconds.
                                                  # :keepalive_maxcount => the maximun number of keepalive packet miss allowed. Defaults to 3
          timeout: 2,                             # :timeout => how long to wait for the initial connection to be made
        }
      end
      SSHKit::Backend::Netssh.pool.idle_timeout = 1   # seconds
    end

    def local_hostname
      @app.local_hostname
    end

    def sudo_user
      @app.sudo_user
    end

    def sudo_password
      @app.sudo_password
    end

    def zip_bundle_path
      app.zip
    end

    def run(entry_point_ops_file, params_hash)
      runtime_env = self
      SSHKit::Backend::LocalPty.new do
        runtime_env.pty = self
        retval = runtime_env.invoke(entry_point_ops_file, params_hash)
        runtime_env.pty = nil
        retval
      end.run
    end

    def invoke(ops_file, hashlike_params)
      ops_file.invoke(self, hashlike_params)
    end

    def find_load_path_that_includes_path(path)
      load_path = [@bundle_load_path, @app_load_path].find {|load_path| load_path.includes_path?(path) }
      raise SymbolResolutionError, "No load path includes the path: #{path}" unless load_path
      load_path
    end

    # returns a Namespace | OpsFile
    def resolve_sibling_symbol(origin_ops_file, symbol_name)
      # if the origin_ops_file's file path is contained within a Bundler::BUNDLE_DIR directory, then we want to consult the @bundle_load_path
      # otherwise, we want to consult the @app_load_path
      load_path = find_load_path_that_includes_path(origin_ops_file.ops_file_path)
      namespace_or_ops_file = load_path.resolve_symbol(origin_ops_file, symbol_name)
      raise SymbolResolutionError, "Symbol '#{symbol_name}' not in load path for #{origin_ops_file.ops_file_path}" unless namespace_or_ops_file
      namespace_or_ops_file
    end

    # returns a Namespace | OpsFile
    def resolve_import_reference(origin_ops_file, import_reference)
      load_path = case import_reference

      # We know we're dealing with a package dependency reference, so we want to do the lookup in the bundle load path, where package dependencies live.
      # Package references are guaranteed to live in the bundle dir
      when PackageDependencyReference, DynamicPackageImportReference
        @bundle_load_path
      when DirectoryReference
        find_load_path_that_includes_path(import_reference.dirname)
      when OpsFileReference
        find_load_path_that_includes_path(import_reference.ops_file_path)
      end

      namespace_or_ops_file = load_path.resolve_import_reference(origin_ops_file, import_reference)

      raise SymbolResolutionError, "Import reference '#{import_reference.summary}' not in load path for #{origin_ops_file.ops_file_path}" unless namespace_or_ops_file

      namespace_or_ops_file
    end

  end

end
