# frozen_string_literal: true

module RubyGBA
  class Builder
    # The on-screen writing verbs, built on the same 5x7 bitmap font: draw_text for
    # words (labels, dialogue) and draw_number for counters (score, damage). They
    # stay separate because a game uses them differently — the only thing they share
    # is the font that renders a glyph. A concern of {Builder}, mixed in flat.
    module Text
      # The font advances this many pixels per character (a 5px glyph + a 1px gap).
      GLYPH_WIDTH = 6

      # How many digit columns draw_number reserves when you don't say. A live
      # number's width isn't known until the game runs, so it draws in a fixed field.
      DEFAULT_DIGITS = 4

      # Draw a line of words at (x, y) with the built-in font: a label, a title, a
      # line of dialogue. The string is fixed when the ROM is built.
      #
      #   draw_text "PRESS START", 76, 100, :gray
      #
      # For a number that changes as the game runs (a score, a counter), use
      # {#draw_number} — a live value can't be spliced into a string, since Ruby
      # resolves `"score: #{n}"` at build time, before the game runs.
      #
      # Characters are 6px wide (5px glyph + 1px gap), 7px tall; text is uppercased
      # and unknown characters are skipped.
      #
      # @param text [String] the words to draw
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param color [Symbol, String, Integer] text color
      def draw_text(text, x, y, color)
        unless text.is_a?(String)
          raise ArgumentError,
                "draw_text draws words (a String); for a number like a score or a counter use " \
                "draw_number — got #{text.inspect}"
        end

        record(Build.draw_text(text, x, y, color))
      end

      # Draw a whole number at (x, y): a score, a damage counter, a timer. The value
      # is timing-agnostic — a fixed number, a variable, or an expression all work:
      #
      #   draw_number 0,      8, 8, :white           # a fixed number
      #   draw_number score,  8, 8, :white           # a live variable
      #   draw_number hp - 1, 8, 8, :white           # an expression
      #
      # It reads naturally — no leading zeros — right-aligned in a +digits+-wide
      # field, so the ones digit stays put and the number grows to the left (the
      # usual score/counter look). Shows non-negative whole numbers; a value wider
      # than +digits+ has its top places dropped, and there's no minus sign yet.
      #
      # @param value [Integer, Symbol, Value] the number to draw
      # @param x [Integer] left edge of the field
      # @param y [Integer] top edge
      # @param color [Symbol, String, Integer] digit color
      # @param digits [Integer] how many digit columns to reserve
      def draw_number(value, x, y, color, digits: DEFAULT_DIGITS)
        unless digits.is_a?(Integer) && digits.positive?
          raise ArgumentError, "draw_number needs a positive number of digits, got #{digits.inspect}"
        end

        case value
        when Integer        then draw_fixed_number(value, x, y, color, digits)
        when Symbol, Value  then draw_live_number(value, x, y, color, digits)
        else
          raise ArgumentError,
                "draw_number draws a number — a value, a variable, or an expression — got #{value.inspect}"
        end
      end

      private

      # A number known at build time: right-align its glyphs in the field now.
      def draw_fixed_number(number, x, y, color, digits)
        text = number.to_s
        col = [digits - text.length, 0].max * GLYPH_WIDTH
        record(Build.draw_text(text, x + col, y, color))
      end

      # A number only known at run time. Work it out once into a hidden var, then
      # draw each column. The bitmap font can't be indexed by a run-time digit, so
      # each column compares its value against 0..9 and draws the one that matches.
      # A "started" flag blanks the leading zeros so it reads as a natural number:
      # a column draws once a non-zero digit has appeared (the ones column always
      # draws, so a value of 0 still shows "0").
      #
      # Every column therefore carries all ten digit glyphs (one is drawn), so a
      # column costs about ten glyph blits of ROM — fine for a HUD; a run-time
      # glyph-by-index draw op would collapse each column to a single blit.
      def draw_live_number(value, x, y, color, digits)
        source = next_number_var
        set(source, value)
        digit = next_number_var
        started = next_number_var
        set(started, 0)

        digits.times do |i|
          place = 10**(digits - 1 - i)
          set(digit, digit_at(source, place))
          col_x = x + i * GLYPH_WIDTH
          if i == digits - 1
            draw_glyph(digit, col_x, y, color) # the ones column always shows
          else
            if_ne(digit, 0) { set(started, 1) }
            if_eq(started, 1) { draw_glyph(digit, col_x, y, color) }
          end
        end
        nil
      end

      # Draw the single digit held in +digit_var+ (0..9) at (x, y) as one
      # draw_digit node — the tree keeps "draw one digit here" as a single intent,
      # and the backend decides how to render it (a font lookup, or a fan-out).
      def draw_glyph(digit_var, x, y, color)
        ensure_var(digit_var)
        record(Build.draw_digit(Build.var_ref(digit_var), x, y, color))
      end

      # The value node for one digit column of the number in +source+:
      # (source / place) mod 10, spelled out since there's no modulo op (mod 10 is
      # q - (q / 10) * 10, a true remainder for a non-negative q).
      def digit_at(source, place)
        quotient = source_over_place(source, place)
        tens = Build.binop(:/, quotient, Build.int(10))
        Build.binop(:-, quotient, Build.binop(:*, tens, Build.int(10)))
      end

      # source / place, skipping the divide for the ones column (place == 1).
      def source_over_place(source, place)
        ref = Build.var_ref(source)
        place == 1 ? ref : Build.binop(:/, ref, Build.int(place))
      end

      # A fresh hidden variable name for one draw_number call's working state.
      # Named per call site, reused every frame.
      def next_number_var
        @number_seq += 1
        :"__number_#{@number_seq}"
      end
    end
  end
end
