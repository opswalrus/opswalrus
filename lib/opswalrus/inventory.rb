require "pathname"
require "tty-editor"
require "yaml"

module OpsWalrus
  class Inventory
    # host_references is an array of host names and  path strings that reference hosts.yaml files
    # tags is an array of strings
    def initialize(host_references = [HostsFile::DEFAULT_FILE_NAME], tags = [])
      @host_references = host_references
      @tags = tags
    end

    def hosts()
      hosts_files, host_strings = @host_references.partition {|ref| File.exist?(ref) }
      inventory_file_hosts = hosts_files.
                                map {|file_path| HostsFile.new(file_path) }.
                                reduce({}) do |host_map, hosts_file|
                                  hosts_file.hosts.each do |host|
                                    (host_map[host] ||= host).tag!(host.tags)
                                  end

                                  host_map
                                end.
                                keys
      untagged_hosts = host_strings.map(&:strip).uniq.map {|host| Host.new(host) }
      all_hosts = untagged_hosts + inventory_file_hosts

      selected_hosts = if @tags.empty?
        all_hosts
      else
        all_hosts.select do |host|
          @tagstags.all? {|t| host.tags.include? t }
        end
      end.reject{|host| host.ignore? }

      selected_hosts.sort_by(&:to_s)
    end

  end
end
