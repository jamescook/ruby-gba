# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    # Which glyphs a program can actually be asked to draw, per font — the
    # tree-shaking pass behind a data-driven font: only reachable glyphs need to be
    # embedded, so a big font used narrowly (a 41-glyph font drawing only a score)
    # shrinks to the handful it really touches.
    #
    # What a draw contributes to its font's reachable set:
    #   * draw_text — its exact characters (the string is fixed when the ROM is
    #     built), folded and filtered through the font (see Font#keys_used).
    #   * draw_digit — the ten digit glyphs 0-9 (a run-time number shows one of them).
    #
    # A run-time *arbitrary* string can't be narrowed this way; when that lands it
    # will carry a developer-declared `chars:` subset, and without one the whole font
    # is reachable. No such draw exists yet, so today every text is knowable exactly.
    module GlyphUsage
      DIGITS = ("0".."9").to_a.freeze

      module_function

      # font name (Symbol) => sorted Array of the glyph keys it may draw.
      def reachable(program)
        usage = Hash.new { |hash, key| hash[key] = Set.new }
        program.walk do |node|
          case node.kind
          when :draw_text then usage[node[:font]].merge(Fonts.get(node[:font]).keys_used(node[:text]))
          when :draw_digit then usage[node[:font]].merge(Fonts.get(node[:font]).keys_used(DIGITS.join))
          end
        end
        usage.transform_values { |set| set.to_a.sort }
      end

      # A one-line-per-font summary: the reachable count against the font's full size,
      # so the tree-shaking is visible (e.g. ":default draws 10 of 41 glyphs").
      def footprint(program)
        reachable(program).map do |name, keys|
          { font: name, drawn: keys.length, total: Fonts.get(name).glyph_count, keys: keys }
        end
      end
    end
  end
end
