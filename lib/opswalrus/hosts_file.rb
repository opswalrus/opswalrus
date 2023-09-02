require "open3"
require "pathname"
require "psych"
require "shale"
require "stringio"
require "tempfile"
require "tty-editor"
require "yaml"
require_relative "host"

module OpsWalrus

  class HostsFile
    DEFAULT_FILE_NAME = "hosts.yaml"

    attr_accessor :hosts_file_path
    attr_accessor :yaml

    def initialize(hosts_file_path)
      @hosts_file_path = File.absolute_path(hosts_file_path)
      @yaml = Psych.safe_load(File.read(hosts_file_path), permitted_classes: [SecretRef]) if File.exist?(hosts_file_path)
    end

    def defaults
      @defaults ||= (@yaml["defaults"] || @yaml["default"] || {})
    end

    # secrets are key/value pairs in which the key is an identifier used throughout the yaml file to reference the secret's value
    # and the associated value is either a Hash or a String.
    # 1. If the secret's value is a Hash, then the Hash must consist of two keys - ids and a secret value:
    #    - the ids field explicitly names the intended audience for the secret value.
    #      The value associated with the ids field is either a String value structured as a comma delimited list of ids,
    #      in which each id is a reference to an id contained within the ids section of the inventory file
    #      OR
    #      the ids field is an Array value in which each element of the array is a reference to an id contained within
    #      the ids section of the inventory file.
    #    - the value field is a String value storing the secret value
    # 2. If the secret's value is a String, then the string is the secret value, and is interpreted to be intended
    #    for use by an audience consisting of all of the ids listed in the ids section of the inventory file.
    #
    # returns a Hash of secret-name/Secret pairs
    def secrets
      @secrets ||= (@yaml["secrets"] || {}).map do |secret_name, secret_attrs|
        audience_ids, secret_value = case secret_attrs
        when Hash
          ids = case ids_value = secret_attrs["ids"]
          when String
            ids_value.split(',').map(&:strip)
          when Array
            ids_value.map {|elem| elem.to_s.strip }
          else
            raise "ids field beloning to secret '#{secret_name}' is of an unknown type: #{ids_value.class.name}: #{ids_value.inspect}"
          end
          value = secret_attrs["value"]
          [ids, value]
        when String
          ids = self.ids.select {|k,v| PublicKey === v }.keys
          value = secret_attrs
          [ids, value]
        else
          raise "Secret '#{secret_name}' has an unexpected type #{secret_attrs.class.name}: #{secret_attrs.inspect}"
        end

        [secret_name, Secret.new(secret_name, secret_value, audience_ids)]
      end.to_h
    end

    def encrypt_secrets!(cipher)
      secrets.each do |secret_name, secret|
        secret.encrypt(cipher)
      end
    end

    # returns a Hash of id-name/(PublicKey | Array String ) pairs
    def ids
      @ids ||= begin
        id_public_key_pairs, alias_id_set_pairs = (@yaml["ids"] || {}).partition{|k,v| String === v }.map(&:to_h)

        named_public_keys = id_public_key_pairs.map do |id_name, public_key_string|
          [id_name, PublicKey.new(id_name, public_key_string)]
        end.to_h

        # named_id_sets = alias_id_set_pairs.map do |id_name, id_array|
        #   referenced_public_keys = id_array.map {|id| named_public_keys[id] }.uniq.compact
        #   [id_name, referenced_public_keys]
        # end.to_h

        # named_public_keys.merge(named_id_sets)

        named_public_keys.merge(alias_id_set_pairs)
      end
    end

    def edit
      tempfile = Tempfile.new
      begin
        decrypt(@hosts_file_path, tempfile)
        tempfile.close(false)   # we want to close the file so that the editor can write to it
        if open_editor(tempfile.path)
          tempfile.open()
          encrypt(tempfile, @hosts_file_path)
        end
      ensure
        file.close rescue nil
        file.unlink   # deletes the temp file
      end
    end

    def decrypt(decrypted_file_path = nil)
      decrypted_file_path ||= @hosts_file_path
      # File.write(decrypted_file_path, to_yaml)
      puts "decrypt and write #{decrypted_file_path}:"
      puts HostsFileMapper.to_yaml(self)
    end

    # when editor fails to open a false status is returned
    def open_editor(path)
      # editor = TTY::Editor.new(raise_on_failure: true)
      # editor.open("/path/to/unknown/file")
      # # => raises TTY::Editor::ComandInvocationError
      TTY::Editor.open(path)
    end

    def encrypt(encrypted_file_path = nil)
      encrypted_file_path ||= @hosts_file_path
      # File.write(encrypted_file_path, to_yaml)
      puts "encrypt and write #{encrypted_file_path}:"
      private_key_file_path = ENV["AGE_ID"] || raise("Path to age identity not specified")
      cipher = AgeEncryptionCipher.new(ids, private_key_file_path)
      encrypt_secrets!(cipher)
      puts to_yaml
      # puts HostsFileMapper.to_yaml(self)
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
        next if ['default', 'defaults', 'secrets', 'ids'].include?(host_ref)

        host_params = host_attrs.is_a?(Hash) ? host_attrs : {}

        Host.new(host_ref, tags(host_ref), host_params, defaults)
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

    def to_yaml(encrypted: true)
      hash = {}
      hash["defaults"] = defaults unless defaults.empty?
      hosts.each do |host|
        hash[host.host] = host.to_h
      end
      hash["secrets"] = secrets
      hash["ids"] = ids

      yaml = Psych.safe_dump(hash, permitted_classes: [SecretRef, Secret, PublicKey])
      yaml.sub(/^---\s*/,"")    # omit the leading line: ---\n
    end

  end

  class PublicKey
    # yaml_tag nil

    def initialize(id_name, public_key)
      @id = id_name
      @public_key = public_key
    end

    def key
      @public_key
    end

    # #init_with and #encode_with are demonstrated here:
    # - https://djellemah.com/blog/2014/07/23/yaml-deserialisation/
    # - https://stackoverflow.com/questions/10629209/how-can-i-control-which-fields-to-serialize-with-yaml
    # - https://github.com/protocolbuffers/protobuf/issues/4391
    # serialise to yaml
    def encode_with(coder)
      # per https://rubydoc.info/stdlib/psych/3.0.0/Psych/Coder#scalar-instance_method
      coder.represent_scalar(nil, @public_key)

      # coder.scalar = @public_key
      # coder['public_key'] = @public_key
    end

    # deserialise from yaml
    def init_with(coder)
      @public_key = coder.scalar
      # @public_key = coder['public_key']
    end
  end

  class PublicKeyMapper < Shale::Mapper
    model PublicKey
    attribute :ids, Shale::Type::String
    attribute :value, Shale::Type::String
  end

  class SecretRef
    def initialize(secret_name)
      @secret_name = secret_name
    end

    # #init_with and #encode_with are demonstrated here:
    # - https://djellemah.com/blog/2014/07/23/yaml-deserialisation/
    # - https://stackoverflow.com/questions/10629209/how-can-i-control-which-fields-to-serialize-with-yaml
    # - https://github.com/protocolbuffers/protobuf/issues/4391
    # serialise to yaml
    def encode_with(coder)
      # The following line seems to have the effect of quoting the @secret_name
      # coder.style = Psych::Nodes::Mapping::FLOW

      if @secret_name
        # don't set tag explicitly, let Psych figure it out from yaml_tag
        # coder.represent_scalar '!days', days.first
        coder.scalar = @secret_name
      # else
      #   # don't set tag explicitly, let Psych figure it out from yaml_tag
      #   # coder.represent_seq '!days', days.to_a
        # coder.seq = @secret_name
      end
    end

    # deserialise from yaml
    def init_with(coder)
      case coder.type
      when :scalar
        @secret_name = coder.scalar
      # when :seq
      #   @secret_name = coder.seq
      else
        raise "Dunno how to handle #{coder.type} for #{coder.inspect}"
      end
    end


    def to_s
      @secret_name
    end
  end
  # YAML.add_domain_type("", "secret") do |type, value|
  #   SecretRef.new(value)
  # end
  YAML.add_tag("!secret", SecretRef)


  class Cipher
    # id_to_public_key_map is a Hash of id-name/(PublicKey | Array String ) pairs
    def initialize(id_to_public_key_map)
      @ids = id_to_public_key_map
    end

    # returns: PublicKey | nil | Array PublicKey
    def dereference(audience_id_reference)
      case ref = @ids[audience_id_reference]
      when PublicKey
        ref
      when Array
        ref.map {|audience_id_reference| dereference(audience_id_reference) }.flatten.compact.uniq
      when Nil
        puts "ID #{audience_id_reference} does not appear in the list of known public key identifiers"
        nil
      else
        raise "ID reference #{audience_id_reference} corresponds to an unknown type of public key or transitive ID reference: #{ref.inspect}"
      end
    end

    # returns: Array PublicKey
    def dereference_all(audience_id_references)
      audience_id_references.map {|audience_id_reference| dereference(audience_id_reference) }.flatten.compact.uniq
    end

    # value is the string value to be encrypted
    # audience_id_references is an Array(String) representing the names associated with public keys in the ids section of the file
    # returns the encrypted text as a String
    def encrypt(value, audience_id_references)
      raise "Not implemented"
    end

    # returns the decrypted text as a String
    def decrypt(value)
      raise "Not implemented"
    end

    def encrypted?(value)
      raise "Not implemented"
    end
  end

  class AgeEncryption
    AGE_ENCRYPTED_FILE_HEADER = '-----BEGIN AGE ENCRYPTED FILE-----'

    def self.encrypt(value, public_keys)
      recipient_args = public_keys.map {|public_key| "-r #{public_key}" }
      cmd = "age -e -a #{recipient_args.join(' ')}"
      stdout, stderr, status = Open3.capture3(cmd, stdin_data: value)
      raise "Failed to run age encryption: `#{cmd}`" unless status.success?
      stdout
    end

    def self.decrypt(value, private_key_file_paths)
      identity_file_args = private_key_file_paths.map {|private_key_file_path| "-i #{private_key_file_path}" }
      cmd = "age -d  #{identity_file_args.join(' ')}"
      stdout, stderr, status = Open3.capture3(cmd, stdin_data: value)
      raise "Failed to run age encryption: `#{cmd}`" unless status.success?
      stdout
    end
  end

  class AgeEncryptionCipher < Cipher
    # id_to_public_key_map is a Hash of id-name/(PublicKey | Array String ) pairs
    def initialize(id_to_public_key_map, private_key_file_path)
      super(id_to_public_key_map)
      @private_key_file_path = private_key_file_path
    end

    # value is the string value to be encrypted
    # audience_id_references is an Array(String) representing the names associated with public keys in the ids section of the file
    # returns the encrypted text as a String
    def encrypt(value, audience_id_references)
      public_keys = dereference_all(audience_id_references)
      AgeEncryption.encrypt(value, public_keys.map(&:key))
    end

    # returns the decrypted text as a String
    def decrypt(value)
      AgeEncryption.decrypt(value, [@private_key_file_path])
    end

    def encrypted?(value)
      value.strip.start_with?(AgeEncryption::AGE_ENCRYPTED_FILE_HEADER)
    end
  end

  class Secret
    def initialize(name, secret_value, id_references)
      @name = name
      @value = secret_value
      @ids = id_references
    end

    # # #init_with and #encode_with are demonstrated here:
    # # - https://djellemah.com/blog/2014/07/23/yaml-deserialisation/
    # # - https://stackoverflow.com/questions/10629209/how-can-i-control-which-fields-to-serialize-with-yaml
    # # - https://github.com/protocolbuffers/protobuf/issues/4391
    # # serialise to yaml
    # def encode_with(coder)
    #   coder['value'] = @value
    # end

    # # deserialise from yaml
    # def init_with(coder)
    #   @value = coder['value']
    # end

    def encrypt(cipher)
      @value = cipher.encrypt(@value, @ids) unless cipher.encrypted?(@value)
      @value
    end

    def decrypt(cipher)
      @value = cipher.decrypt(@value) if cipher.encrypted?(@value)
      @value
    end
  end

  class SecretMapper < Shale::Mapper
    model Secret

    attribute :ids, Shale::Type::String
    attribute :value, Shale::Type::String
  end

  class HostsFileMapper < Shale::Mapper
    model HostsFile

    # attribute :defaults, Shale::Type::String
    # attribute :hosts, HostMapper, collection: true
    # attribute :secrets, SecretMapper, collection: true
    # attribute :ids, Shale::Type::String, collection: true

    yaml do
      map 'defaults', using: { from: :defaults_from_yaml, to: :defaults_to_yaml }
    end

    def defaults_from_yaml(model, value)
      model.defaults = value
      # model[:street] = value['street']
      # model[:city] = value['city']
    end

    def defaults_to_yaml(model, doc)
      doc['defaults'] = model.defaults
    end
  end

end
