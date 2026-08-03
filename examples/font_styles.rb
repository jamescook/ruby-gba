#!/usr/bin/env ruby
# frozen_string_literal: true

# Font styles — the same word drawn in three fonts, two of them defined right here
# in the build block with `font :name do … end` (the sibling of `image`).
#
# The built-in :default font is 5x7 uppercase. A game can define its own: this one
# adds a rounded lowercase font and a slanted "script" font, each just a set of
# little glyph bitmaps, then picks them with draw_text font:. Register once, use
# anywhere.
#
# Run it to build examples/font_styles.gba:
#   ruby examples/font_styles.rb

require_relative "../lib/ruby_gba"

module FontStyles
  GAME = RubyGBA.game("FONTSTY", code: "BFSY", maker: "01") do
    screen :bitmap
    clear_screen :black

    # A rounded lowercase font, 5x5 per glyph — enough letters for the demo word.
    font :lower do
      glyph "h", <<~ART
        #....
        #....
        ####.
        #...#
        #...#
      ART
      glyph "e", <<~ART
        .....
        .###.
        ####.
        #....
        .###.
      ART
      glyph "l", <<~ART
        ##...
        .#...
        .#...
        .#...
        .##..
      ART
      glyph "o", <<~ART
        .....
        .###.
        #...#
        #...#
        .###.
      ART
    end

    # The same letters sheared right for a stylized "script" look.
    font :script do
      glyph "h", <<~ART
        ..#..
        ..#..
        ..###
        .##.#
        ##..#
      ART
      glyph "e", <<~ART
        .....
        ..###
        .####
        .##..
        ..###
      ART
      glyph "l", <<~ART
        ...##
        ..##.
        ..#..
        .##..
        ##...
      ART
      glyph "o", <<~ART
        .....
        ..###
        .##.#
        .#.##
        .###.
      ART
    end

    draw_text "HELLO", 8, 12, :white               # built-in 5x7 uppercase
    draw_text "hello", 8, 40, :green, font: :lower  # our lowercase font
    draw_text "hello", 8, 64, :cyan,  font: :script # our slanted font
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

FontStyles::GAME.write_if_main
