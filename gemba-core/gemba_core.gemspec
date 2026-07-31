# frozen_string_literal: true

require_relative "lib/gemba_core/version"

Gem::Specification.new do |spec|
  spec.name        = "gemba_core"
  spec.version     = GembaCore::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless libmgba binding for GBA dev/test verification"
  spec.description  = <<~DESC
    A lean, headless binding to libmgba's mCore: boot a GBA ROM and step it one
    frame at a time, reading back video, audio, and memory as plain Ruby data.
    No SDL2 or Tk — this is the dev/test verification core split out of gemba.
    Not published: it lives inside ruby-gba for development use only.
  DESC
  spec.license     = "MIT" # our binding code; libmgba is linked separately (MPL-2.0)
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/gemba_core_ext/*.{c,h,rb}",
    "README.md"
  ]
  spec.require_paths = ["lib", "ext/gemba_core_ext"]
  spec.extensions    = ["ext/gemba_core_ext/extconf.rb"]

  # Runtime dependency is libmgba, a native library found at build time by
  # extconf.rb (Homebrew, pkg-config, or MGBA_DIR) — not a RubyGem.
  spec.metadata["rubygems_mfa_required"] = "true"
end
