require_relative "lib/ruby_gba/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby-gba"
  spec.version       = RubyGBA::VERSION
  spec.authors       = ["James Cook"]
  spec.email         = ["jcook.rubyist@gmail.com"]

  spec.summary       = "Ruby DSL for building GBA ROMs"
  spec.description   = "A Ruby DSL that generates valid Game Boy Advance ROM files"
  spec.homepage      = "https://github.com/jamescook/ruby-gba"
  spec.licenses      = ["MIT"]

  spec.files         = Dir.glob("{lib,test,bin}/**/*").select { |f| File.file?(f) } +
                       %w[ruby-gba.gemspec Rakefile]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 6.0"
  # The emulator used by the Verifier and integration tests is gemba-core, a
  # headless libmgba probe vendored in-repo under gemba-core/ (not a published
  # gem, so not listed here). It builds against a system libmgba; tests skip
  # gracefully when it isn't built. See gemba-core/README.md.
end
