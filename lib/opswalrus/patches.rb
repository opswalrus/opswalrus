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
