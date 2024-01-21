# frozen_string_literal: true

require_relative "lib/opswalrus/version"

Gem::Specification.new do |spec|
  spec.name                  = "opswalrus"
  spec.version               = OpsWalrus::VERSION
  spec.authors               = ["David Ellis"]
  spec.email                 = ["david@conquerthelawn.com"]

  spec.summary               = "opswalrus is a tool that runs scripts against a fleet of hosts"
  spec.description           = "opswalrus is a tool that runs scripts against a fleet of hosts hosts. It's kind of like Ansible, but aims to be simpler to use."
  spec.homepage              = "https://github.com/opswalrus/opswalrus"
  spec.license               = "EPL-2.0"
  spec.required_ruby_version = ">= 2.6.0"

  # spec.metadata["allowed_push_host"] = "Set to your gem server - https://example.com"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/opswalrus/opswalrus"
  # spec.metadata["changelog_uri"] = "Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) || f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # gem dependencies
  spec.add_dependency "activesupport", "~> 7.0"
  spec.add_dependency "binding_of_caller", "~> 1.0"
  spec.add_dependency "citrus", "~> 3.0"
  spec.add_dependency "gli", "~> 2.21"
  spec.add_dependency "git", "~> 1.18"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "rubyzip", "~> 2.3"
  spec.add_dependency "semantic_logger", "~> 4.13"
  spec.add_dependency "tty-editor", "~> 0.7"
  spec.add_dependency "tty-exit", "~> 0.1"
  spec.add_dependency "tty-option", "~> 0.3"

  spec.add_dependency "bcrypt_pbkdf", "~> 1.1"
  spec.add_dependency "ed25519", "~> 1.3"
  spec.add_dependency "kleene", ">= 0"
  spec.add_dependency "sshkit", "~> 1.21"       # sshkit uses net-ssh, which depends on bcrypt_pbkdf and ed25519 to dynamically add support for ed25519 if those two gems are present

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
