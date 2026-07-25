#!/usr/bin/env ruby
# frozen_string_literal: true

# Fonts — the same number drawn in two fonts, so you can see per-text font selection.
#
# draw_text / draw_number take a font: name from the Fonts registry. The score here
# is drawn once in the built-in 5x7 :default font and once in the compact 3x5 :tiny
# font — same value, visibly different size. A game reaches for :tiny when a HUD
# needs to pack numbers into a small corner. New fonts register the same way, and
# each carries its own metrics, so the framework sizes and costs text per font.
#
# Run it to build examples/fonts.gba:
#   ruby examples/fonts.rb

require_relative "../lib/ruby_gba"

module FontsDemo
  SCORE = 12_345

  GAME = proc do
    screen :bitmap
    clear_screen :black

    # The default 5x7 font.
    draw_text "DEFAULT", 8, 8, :white
    draw_number SCORE, 8, 18, :green, digits: 5

    # The compact 3x5 :tiny font — the same number, half the height.
    draw_text "TINY", 8, 44, :white
    draw_number SCORE, 8, 54, :green, digits: 5, font: :tiny

    halt
  end

  def self.build_rom
    RubyGBA.build("FONTS", code: "BFON", maker: "01", &GAME)
  end

  # The IR program on its own — what the headless interpreter runs in tests.
  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = FontsDemo.build_rom
  output = File.join(__dir__, "fonts.gba")
  rom.write(output)
  puts "Built fonts.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to see the per-frame draw cost — the tiny number plots fewer pixels.
  rom.explain if ENV["EXPLAIN"]
end
