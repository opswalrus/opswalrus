# frozen_string_literal: true

require_relative "lib/opswalrus/version"

Gem::Specification.new do |spec|
  spec.name = "opswalrus"
  spec.version = OpsWalrus::VERSION
  spec.authors = ["David Ellis"]
  spec.email = ["david@conquerthelawn.com"]

  spec.summary = "opswalrus is a tool that runs scripts against a fleet of hosts"
  spec.description = "opswalrus is a tool that runs scripts against a fleet of hosts hosts. It's kind of like Ansible, but aims to be simpler to use."
  spec.homepage = "https://github.com/opswalrus/opswalrus"
  spec.required_ruby_version = ">= 2.6.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/opswalrus/opswalrus"
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

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
  spec.add_dependency "citrus"
  spec.add_dependency "gli"
  spec.add_dependency "git"
  spec.add_dependency "rubyzip"

  spec.add_dependency "bcrypt_pbkdf"
  spec.add_dependency "ed25519"
  spec.add_dependency "sshkit"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
