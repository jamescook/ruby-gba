# frozen_string_literal: true

require_relative "lib/ruby_gba_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-gba-emulator"
  spec.version     = RubyGBAEmulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless libmgba binding for GBA dev/test verification"
  spec.description  = <<~DESC
    A lean, headless binding to libmgba's mCore: boot a GBA ROM and step it one
    frame at a time, reading back video, audio, and memory as plain Ruby data.
    No SDL2 or Tk. ruby-gba uses it to verify and profile the cartridges it
    builds; building one needs none of this.
  DESC
  spec.homepage    = "https://github.com/jamescook/ruby-gba"
  spec.license     = "MIT" # our binding code; libmgba is linked separately (MPL-2.0)
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/ruby_gba_emulator_ext/*.{c,h,rb}",
    "README.md"
  ]

  # lib ONLY. The source ext/ directory is deliberately not a require path: RubyGems puts the
  # extension it BUILDS on the load path itself, in a directory named for the Ruby ABI, and
  # listing the source directory here would put a hand-compiled library ahead of it. That is
  # not hypothetical — it is what made installing this gem buy nothing, because `rake compile`
  # left a binary in the source tree and that one always won.
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/ruby_gba_emulator_ext/extconf.rb"]

  # Runtime dependency is libmgba, a native library found at build time by
  # extconf.rb (Homebrew, pkg-config, or MGBA_DIR) — not a RubyGem.
  spec.metadata["rubygems_mfa_required"] = "true"
end
