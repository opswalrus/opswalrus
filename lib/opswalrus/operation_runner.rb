require "random/formatter"
require "socket"

require_relative "runtime_environment"
require_relative "ops_file"

module OpsWalrus
  class OperationRunner
    attr_accessor :app
    attr_accessor :entry_point_ops_file

    def initialize(app, entry_point_ops_file)
      @app = app
      @entry_point_ops_file = entry_point_ops_file
      # @entry_point_ops_file_in_bundle_dir = bundle!(@entry_point_ops_file)
    end

    # def bundle!(entry_point_ops_file)
    #   path_to_entry_point_ops_file_in_bundle_dir = @app.bundler.build_bundle_for_ops_file(entry_point_ops_file)
    #   OpsFile.new(app, path_to_entry_point_ops_file_in_bundle_dir)
    # end

    def sudo_user
      @app.sudo_user
    end

    def sudo_password
      @app.sudo_password
    end

    # runtime_kv_args is an Array(String) of the form: ["arg1:val1", "arg1:val2", ...]
    # irb(main):057:0> build_params_hash(["names:foo", "names:bar", "names:baz", "age:5", "profile:name:corge", "profile:language:en", "height:5ft8in"])
    # => {"names"=>["foo", "bar", "baz"], "age"=>"5", "profile"=>{"name"=>"corge", "language"=>"en"}, "height"=>"5ft8in"}
    def build_params_hash(runtime_kv_args, params_json_hash: nil)
      runtime_kv_args.reduce(params_json_hash || {}) do |memo, kv_pair_string|
        param_name, str_value = kv_pair_string.split(":", 2)
        key, value = str_value.split(":", 2)
        if pre_existing_value = memo[param_name]
          memo[param_name] = if value    # we're dealing with a Hash parameter value
                               pre_existing_value.merge(key => try_convert(value))
                             else        # we're dealing with an Array parameter value or a scalar parameter value
                               array = pre_existing_value.is_a?(Array) ? pre_existing_value : [pre_existing_value]
                               array << try_convert(str_value)
                             end
        else
          memo[param_name] = if value    # we're dealing with a Hash parameter value
                               {key => try_convert(value)}
                             else        # we're dealing with an Array parameter value or a scalar parameter value
                               try_convert(str_value)
                             end
        end
        memo
      end
    end

    def try_convert(value)
      case value.downcase
      when 'true'
        true
      when 'false'
        false
      when /^[0-9]+$/
        value.to_i
      when /^[0-9]+\.[0-9]+$/
        value.to_f
      else
        value
      end
    end

    # runtime_kv_args is an Array(String) of the form: ["arg1:val1", "arg1:val2", ...]
    # params_json_hash is a Hash representation of a JSON string
    # returns:
    #   Invocation::Success on success
    #   or Invocation::EarlyExitError when the user's script intentionally exits early without running to completion
    #   or Invocation::SshError when a connection error condition is raised
    #   or Invocation::RuntimeError when some known error condition is raised
    #   or Invocation::UnhandledError when some unknown error condition is raised
    def run(runtime_kv_args, params_json_hash: nil)
      params_hash = build_params_hash(runtime_kv_args, params_json_hash: params_json_hash)

      App.instance.trace "Script:"
      App.instance.trace @entry_point_ops_file.script

      result = begin
        # update the bundle for the package
        # @entry_point_ops_file.package_file&.bundle!   # we don't do this here because when the script is run
                                                        # on a remote host, the package references may be invalid
                                                        # so we will be unable to bundle at runtime on the remote host
        catch(:exit_now) do
          ruby_script_return = RuntimeEnvironment.new(app).run(@entry_point_ops_file, params_hash)
          Invocation::Success.new(ruby_script_return)
        end
      rescue SSHKit::Command::Failed => e
        App.instance.error "Runtime error, command failed: #{e.message}"
        Invocation::SshError.new(e)
      rescue Error => e
        # puts "OperationRunner#run - #{Time.now.strftime('%s%L')}"
        App.instance.error "Runtime error: Ops script crashed."
        App.instance.error e.message
        App.instance.error e.backtrace.take(10).join("\n")
        Invocation::RuntimeError.new(e)
      rescue => e
        # puts "OperationRunner#run - #{Time.now.strftime('%s%L')}"
        App.instance.error "Unhandled runtime error: Ops script crashed."
        App.instance.error e.class
        App.instance.error e.message
        App.instance.error e.backtrace.take(10).join("\n")
        Invocation::UnhandledError.new(e)
      end

      result
    end
  end
end
