#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes each console's answers page under .claude/dsl/ again from its table (Console::Answers),
# the one place every verb's answer on that console is decided. Run it after changing an answer;
# a test fails until you do.
require_relative "../lib/vblank"

VBlank::Console.kits.each do |kit|
  path = VBlank.root.join(kit.answers::PAGE)
  File.write(path, kit.answers_page)
  puts "Wrote #{path.relative_path_from(VBlank.root)}"
end
