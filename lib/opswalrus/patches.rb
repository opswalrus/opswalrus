require 'active_support'
require 'active_support/core_ext/hash'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/string'
require 'json'
require 'pathname'

class EasyNavProxy
  extend Forwardable

  # indexable_obj must implement #respond_to? and #has_key?
  def initialize(indexable_obj)
    @obj = indexable_obj
  end

  def_delegators :@obj, :[], :to_s, :inspect, :hash, :===, :==, :eql?, :kind_of?, :is_a?, :instance_of?, :respond_to?, :<=>

  def easynav
    self
  end

  def respond_to_missing?(method, *)
    @obj.respond_to?(method) || @obj.has_key?(method)
  end
  def method_missing(method, *args, **kwargs, &block)
    if @obj.respond_to?(method)
      @obj.method(method).call(*args, **kwargs, &block)
    elsif @obj.has_key?(method)
      value = self[method]
      case value
      when Array, Hash
        EasyNavProxy.new(value)
      else
        value
      end
    end
  end

  # Serialize Foo object with its class name and arguments
  def to_json(*args)
    @obj.to_json(*args)
  end
end

class Hash
  def easynav
    EasyNavProxy.new(self.with_indifferent_access)
  end
end

module Enumerable
  # calls the block with successive elements; returns the first truthy object returned by the block
  def find_map(&block)
    each do |element|
      mapped_value = block.call(element)
      return mapped_value if mapped_value
    end
    nil
  end
end

class Array
  def has_key?(key)
    key.is_a?(Integer) && key < size
  end
  def easynav
    EasyNavProxy.new(self)
  end
end

class String
  def escape_single_quotes
    gsub("'"){"\\'"}
  end

  def to_pathname
    Pathname.new(self)
  end

  def parse_json
    JSON.parse(self)
  end
end

class Pathname
  def to_pathname
    self
  end
end

class String
  def boolean!(default: false)
    boolean_str = strip.downcase
    case boolean_str
    when "true"
      true
    when "false"
      false
    else
      default
    end
  end

  def string!(default: "")
    self
  end

  def integer!(default: 0)
    to_i
  end
end

class Integer
  def boolean!(default: false)
    true
  end

  def string!(default: "")
    to_s
  end

  def integer!(default: 0)
    self
  end
end

class Float
  def boolean!(default: false)
    true
  end

  def string!(default: "")
    to_s
  end

  def integer!(default: 0)
    to_i
  end
end

class NilClass
  def boolean!(default: false)
    default
  end

  def string!(default: "")
    default
  end

  def integer!(default: 0)
    default
  end
end

class TrueClass
  def boolean!(default: false)
    self
  end

  def string!(default: "")
    to_s
  end

  def integer!(default: 0)
    default
  end
end

class FalseClass
  def boolean!(default: false)
    self
  end

  def string!(default: "")
    to_s
  end

  def integer!(default: 0)
    default
  end
end
