require 'json'
require 'pathname'

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
