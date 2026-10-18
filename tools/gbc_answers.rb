#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes .claude/dsl/game-boy-color.md again from Console::GBCFeatures, the one place every verb's
# Game Boy Color answer is decided. Run it after changing an answer; a test fails until you do.
require_relative "../lib/ruby_gba"

path = RubyGBA.root.join(".claude/dsl/game-boy-color.md")
File.write(path, RubyGBA::Console::GBCFeatures.reference(not_yet: RubyGBA::IR::Backends::GBC::Lowering::NOT_LOWERED_YET))
puts "Wrote #{path.relative_path_from(RubyGBA.root)}"
