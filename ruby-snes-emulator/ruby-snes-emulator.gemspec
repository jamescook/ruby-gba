# frozen_string_literal: true

require_relative "lib/ruby_snes_emulator/version"

Gem::Specification.new do |spec|
  spec.name        = "ruby-snes-emulator"
  spec.version     = RubySNESEmulator::VERSION
  spec.authors     = ["James Cook"]
  spec.summary     = "Headless bsnes binding for Super Nintendo dev/test verification"
  spec.description = <<~DESC
    A lean, headless Super Nintendo: bsnes, built as a libretro core with a small patch that
    hands over the console's memories, driven from Ruby through Fiddle. Play a cartridge a
    frame at a time and read back its picture, work RAM, video RAM, colour memory, sprite
    table and registers. VBlank uses it to check the cartridges it builds; building one needs
    none of this.
  DESC
  spec.homepage    = "https://github.com/jamescook/vblank"
  spec.license     = "MIT" # our binding code; bsnes is built separately (GPLv3)
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "core/*.patch", "Rakefile", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "fiddle"
  spec.metadata["rubygems_mfa_required"] = "true"
end
