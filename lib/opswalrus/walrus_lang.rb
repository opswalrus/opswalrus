require "citrus"
require "ostruct"
require "stringio"

module WalrusLang
  module Templates
    def render(binding)
      captures(:template).map{|t| t.render(binding) }.join
    end
  end

  module Template
    def render(binding)
      s = StringIO.new
      if mustache = capture(:mustache)
        s << capture(:pre).value
        s << mustache.render(binding)
        s << capture(:post).value
      else
        s << capture(:fallthrough).value
      end
      s.string
    end
  end

  module Mustache
    def render(binding)
      eval(capture(:expr).render(binding), binding)
    end
  end

  Grammar = <<-GRAMMAR
    grammar WalrusLang::Parser
      rule templates
        (template*) <WalrusLang::Templates>
      end

      rule template
        ((pre:(non_mustache?) mustache post:(non_mustache?)) | fallthrough:non_mustache) <WalrusLang::Template>
      end

      rule before_mustache
        ~'{{'
      end

      rule non_mustache
        ~('{{' | '}}')
      end

      rule mustache
        ('{{' expr:templates '}}') <WalrusLang::Mustache>
      end
    end
  GRAMMAR

  Citrus.eval(Grammar)

  # binding_obj : Binding | Hash
  def self.render(template, binding_obj)
    binding_obj = binding_obj.to_binding if binding_obj.respond_to?(:to_binding)
    ast = WalrusLang::Parser.parse(template)
    ast.render(binding_obj)
  end
end

class Hash
  def to_binding
    OpenStruct.new(self).instance_eval { binding }
  end
end

class Binding
  def local_vars_hash
    local_variables.map {|s| [s.to_s, local_variable_get(s)] }.to_h
  end
end

def mustache(&block)
  template_string = block.call
  template_string =~ /{{.*}}/ ? WalrusLang.render(block.call, block.binding) : template_string
end


# foo = 1
# bar = 2
# # m = TemplateLang.parse("abc; {{ 'foo' * bar }} def ")
# m = WalrusLang::Parser.parse("abc; {{ 'foo{{1+2}}' * bar }} def {{ 4 * 4 }}; def")
# # m = TemplateLang.parse("a{{b{{c}}d}}e{{f}}g{{h{{i{{j{{k{{l}}m{{n}}o}}p}}}}}}")
# # puts m.dump
# puts m.render(binding)

# puts(mustache { "abc {{ 1 + 2 }} def" })
