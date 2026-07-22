# frozen_string_literal: true

module RubyGBA
  class Builder
    # The text verbs: draw strings and single digits with the built-in 5x7 bitmap
    # font. A concern of {Builder}, mixed in so draw_text/draw_digit are flat verbs.
    module Text
      # Draw a text string at (x, y) using the built-in 5x7 bitmap font.
      # Each character is 6px wide (5px glyph + 1px gap), 7px tall.
      # All text is uppercased. Unsupported characters are skipped.
      #
      # @param text [String] text to render
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param c [Symbol, String, Integer] text color
      def draw_text(text, x, y, c)
        record(Build.draw_text(text, x, y, c))
      end

      # Draw a single-digit number (0-9) at (x, y).
      # For multi-digit, call multiple times with offset.
      #
      # @param digit [Integer] 0-9
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param c [Symbol, String, Integer] color
      def draw_digit(digit, x, y, c)
        draw_text(digit.to_s, x, y, c)
      end
    end
  end
end
