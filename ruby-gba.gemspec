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

  # compile_flags.txt is written for an editor on the machine it names folders on (see
  # Native::Zig), so it is no part of the gem.
  spec.files         = Dir.glob("{lib,test,bin}/**/*").select { |f| File.file?(f) && File.basename(f) != "compile_flags.txt" } +
                       %w[ruby-gba.gemspec Rakefile]
  spec.bindir        = "bin"
  spec.executables   = ["ruby-gba"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rubocop", "~> 1.81"
  spec.add_development_dependency "rubocop-performance", "~> 1.26"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
