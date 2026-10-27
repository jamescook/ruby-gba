# frozen_string_literal: true

require "json"
require "zlib"

module VBlank
  module Graphics
    # THE LETTERS THE WINDOW MENU IS WRITTEN IN (Live::WindowMenu): Inter at 15 points, drawn once
    # into pictures by tools/make_menu_font.rb and kept in lib/vblank/data/menu_font/, so no frontend
    # needs a font library or a font file. A frontend puts a density's picture of every letter
    # (#atlas) on the screen's card once, then writes a word by copying each letter out of it to
    # where #layout says.
    #
    # There are pictures at two densities: one pixel a point, for an ordinary screen, and two, for a
    # Retina one. A screen of any other density is written with the nearer of the two, scaled, so a
    # letter is never drawn from a picture much smaller than it is shown.
    class MenuFont
      # Found beside this file rather than from VBlank.root: a game written out as one Ruby file
      # (IR::Backends::Ruby#script) carries this file without root.rb, and the letters with it, in
      # CARRIED.
      PATH = Ractor.make_shareable(File.expand_path("../data/menu_font/inter-15.json", __dir__))

      # One density's picture of every letter: +alpha+ is how much of each pixel the letters cover,
      # 0 to 255, a byte each, +width+ by +height+, a row at a time from the top.
      Atlas = Data.define(:density, :width, :height, :alpha)

      # Where a letter of a word goes: the rectangle of the atlas it is in (+from+, as x, y, width,
      # height) and the rectangle of the screen it is copied to (+to+), both in pixels.
      Letter = Data.define(:from, :to)

      # The library's letters, read once for each Ractor: from PATH, or from CARRIED in a game
      # written out as one Ruby file.
      def self.load
        Ractor.current[:vblank_menu_font] ||= new(defined?(CARRIED) ? CARRIED : File.read(PATH, encoding: Encoding::UTF_8))
      end

      # The font as read from +text+, the file's JSON.
      def initialize(text)
        @data = JSON.parse(text)
        @atlases = {}
      end

      # The font's size, in points.
      def points = @data.fetch("points")

      # The picture the letters at +density+ (pixels a point) are copied from.
      def atlas(density)
        at = nearest_density(density)
        @atlases[at] ||= begin
          data = @data.fetch("densities").fetch(at.to_s)
          Atlas.new(density: at, width: data.fetch("atlas_width"), height: data.fetch("atlas_height"),
                    alpha: Zlib::Inflate.inflate(data.fetch("alpha").unpack1("m0")))
        end
      end

      # Every letter the picture at +density+ has, by the letter: where it is in the picture, where
      # it sits from the pen and the top of the line, and how far the pen moves after it — x, y,
      # width, height, left, top and advance, in the picture's own pixels.
      def glyphs(density) = measures_at(density).fetch("glyphs")

      # The pairs of letters that sit closer, or further apart, than their advances say, by the two
      # letters together: how many of the picture's pixels to move the second.
      def kerning(density) = measures_at(density).fetch("kerning")

      # How tall a line of words is at +density+, in pixels.
      def line_height(density) = (measures_at(density).fetch("line_height") * scale(density)).round

      # How wide +words+ are at +density+, in pixels: the pen's walk from the first letter to the end
      # of the last, closer or further apart where the font says a pair of letters goes.
      def width(words, density) = pen_walk(words, density) { nil }.round

      # Each letter of +words+, written with the top left of their line at +x+, +y+ (pixels), at
      # +density+. A letter the font does not have is written as a question mark, and a space is
      # only room.
      def layout(words, x, y, density)
        scale = scale(density)
        glyphs = measures_at(density).fetch("glyphs")
        letters = []
        pen_walk(words, density) do |letter, pen|
          from_x, from_y, wide, high, left, top, = glyphs.fetch(letter)
          next if wide.zero?

          letters << Letter.new(from: [from_x, from_y, wide, high],
                                to: [(x + ((pen + left) * scale)).round, (y + (top * scale)).round,
                                     (wide * scale).round, (high * scale).round])
        end
        letters
      end

      private

      ADVANCE = 6 # where in a letter's measures the pen's move after it is

      def nearest_density(density) = density >= 1.5 ? 2 : 1

      def scale(density) = density.to_f / nearest_density(density)

      def measures_at(density) = @data.fetch("densities").fetch(nearest_density(density).to_s)

      # Walks the pen along +words+ in the atlas's own pixels, handing each letter and where the pen
      # is to the block, and gives how far it went, in the screen's pixels.
      def pen_walk(words, density)
        data = measures_at(density)
        glyphs = data.fetch("glyphs")
        kerning = data.fetch("kerning")
        pen = 0
        previous = nil
        words.each_char do |letter|
          letter = "?" unless glyphs.key?(letter)
          pen += kerning.fetch(previous + letter, 0) if previous
          yield letter, pen
          pen += glyphs.fetch(letter)[ADVANCE]
          previous = letter
        end
        pen * scale(density)
      end
    end
  end
end
