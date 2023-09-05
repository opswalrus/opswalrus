require "binding_of_caller"
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

  def self.eval(template_string, bindings_from_stack_frame_offset = 1)
    binding_from_earlier_stack_frame = binding.of_caller(bindings_from_stack_frame_offset)
    template_string =~ /{{.*}}/ ? WalrusLang.render(template_string, binding_from_earlier_stack_frame) : template_string
  end
end

class String
  def render_template(hash)
    WalrusLang.render(self, hash)
  end

  # bindings_from_stack_frame_offset is a count relative to the stack from from which #mustache is called
  def mustache(bindings_from_stack_frame_offset = 0)
    base_offset = 2
    WalrusLang.eval(self, base_offset + bindings_from_stack_frame_offset)
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


# foo = 1
# bar = 2
# # m = TemplateLang.parse("abc; {{ 'foo' * bar }} def ")
# m = WalrusLang::Parser.parse("abc; {{ 'foo{{1+2}}' * bar }} def {{ 4 * 4 }}; def")
# # m = TemplateLang.parse("a{{b{{c}}d}}e{{f}}g{{h{{i{{j{{k{{l}}m{{n}}o}}p}}}}}}")
# # puts m.dump
# puts m.render(binding)

# puts("abc {{ 1 + 2 }} def".mustache)

# irb(main):096:0> a=5
# => 5
# irb(main):097:0> b=8
# => 8
# irb(main):098:0> "abc {{ a + b }} def".mustache
# => "abc 13 def"
