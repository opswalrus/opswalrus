require "pathname"
require "yaml"
require_relative "host"

module OpsWalrus
  class HostsFile
    attr_accessor :hosts_file_path
    attr_accessor :yaml

    def initialize(hosts_file_path)
      @hosts_file_path = File.absolute_path(hosts_file_path)
      @yaml = YAML.load(File.read(hosts_file_path)) if File.exist?(hosts_file_path)
      # puts @yaml.inspect
    end

    def defaults
      @defaults ||= (@yaml["defaults"] || @yaml["default"] || {})
    end

    # returns an Array(Host)
    def hosts
      # @yaml is a map of the form:
      # {
      #   "198.23.249.13"=>{"hostname"=>"web1", "tags"=>["monopod", "racknerd", "vps", "2.5gb", "web1", "web", "ubuntu22.04"]},
      #   "107.175.91.150"=>{"tags"=>["monopod", "racknerd", "vps", "2.5gb", "pbx1", "pbx", "ubuntu22.04"]},
      #   "198.23.249.16"=>{"tags"=>["racknerd", "vps", "4gb", "kvm", "ubuntu20.04", "minecraft"]},
      #   "198.211.15.34"=>{"tags"=>["racknerd", "vps", "1.5gb", "kvm", "ubuntu20.04", "blog"]},
      #   "homeassistant.locallan.network"=>{"tags"=>["local", "homeassistant", "home", "rpi"]},
      #   "synology.locallan.network"=>{"tags"=>["local", "synology", "nas"]},
      #   "pfsense.locallan.network"=>false,
      #   "192.168.56.10"=>{"tags"=>["web", "vagrant"]}
      # }
      @yaml.map do |host_ref, host_attrs|
        next if host_ref == "default" || host_ref == "defaults"   # this maps to a nil

        host_params = host_attrs.is_a?(Hash) ? host_attrs : {}

        Host.new(host_ref, tags(host_ref), defaults.merge(host_params))
      end.compact
    end

    def tags(host)
      host_attrs = @yaml[host]

      case host_attrs
      when Array
        tags = host_attrs
        tags.compact.uniq
      when Hash
        tags = host_attrs["tags"] || []
        tags.compact.uniq
      end || []
    end
  end
end
