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
      # Define a font from little glyph bitmaps, the way {#image} defines a bitmap
      # from ASCII art — then `draw_text` can pick it. Inside the block, `glyph`
      # gives a character its art; a lit pixel is the +on+ character (default "#"),
      # anything else is blank. Glyphs share one height but may differ in width — a
      # narrow "I" beside a wide "M" renders proportionally, not on a fixed grid.
      #
      #   font :heavy do
      #     glyph "A", <<~ART
      #       ###
      #       # #
      #       ###
      #     ART
      #   end
      #   draw_text "A", 10, 10, :white, font: :heavy   # define with `font`, select with `font:`
      #
      # @param name [Symbol] the name it registers under (used as draw_text's font:)
      # @param on [String] the character that marks a lit pixel
      # @param spacing [Integer] blank pixels between characters
      # @param fold [Symbol, nil] :upper to render any case with these glyphs
      # @return [Symbol] the font name
      def font(name, on: "#", spacing: 1, fold: nil, &block)
        raise ArgumentError, "font :#{name} needs a block: font :#{name} do ... end" unless block

        definition = Font::Definition.new(name, on: on)
        definition.instance_eval(&block)
        Fonts.register(name, definition.to_font(spacing: spacing, fold: fold))
        name
      end

      # @param color [Symbol, String, Integer] text color
      # @param font [Symbol] a font registered in {Fonts} (defaults to :default)
      def draw_text(text, x, y, color, font: :default)
        unless text.is_a?(String)
          raise ArgumentError,
                "draw_text draws words (a String). For a number like a score or a counter, use " \
                "draw_number. Got #{text.inspect}."
        end
        Fonts.get(font) # fail early with a friendly error on an unknown font name

        # A tiled screen has no framebuffer to paint into, so text is drawn as little
        # sprite glyphs the console composites each frame — declared once, like a
        # sprite (see #draw_text_tiled).
        if @screen_mode == :tiled
          require_hud_declared_once!("draw_text")
          return draw_text_tiled(text, x, y, color, font)
        end

        record(Build.draw_text(text, x, y, color, font: font))
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
      def draw_number(value, x, y, color, digits: DEFAULT_DIGITS, font: :default)
        unless digits.is_a?(Integer) && digits.positive?
          raise ArgumentError, "draw_number needs a positive number of digits. Got #{digits.inspect}."
        end

        # On a tiled screen, a number is drawn as sprite glyphs, declared once and
        # left to update itself each frame (see #draw_number_tiled).
        if @screen_mode == :tiled
          require_hud_declared_once!("draw_number")
          return draw_number_tiled(value, x, y, color, digits, font)
        end

        case value
        when Integer        then draw_fixed_number(value, x, y, color, digits, font)
        when Symbol, Value  then draw_live_number(value, x, y, color, digits, font)
        else
          raise ArgumentError,
                "draw_number draws a number: a value, a variable, or an expression. Got #{value.inspect}."
        end
      end

      private

      # A number known at build time: right-align its glyphs in the field now. The
      # column step is the chosen font's cell width, so a narrower font packs tighter.
      def draw_fixed_number(number, x, y, color, digits, font)
        text = number.to_s
        col = [digits - text.length, 0].max * Fonts.get(font).cell_w
        record(Build.draw_text(text, x + col, y, color, font: font))
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
      def draw_live_number(value, x, y, color, digits, font)
        source = next_number_var
        set(source, value)
        digit = next_number_var
        started = next_number_var
        set(started, 0)

        cell = Fonts.get(font).cell_w
        digits.times do |i|
          place = 10**(digits - 1 - i)
          set(digit, digit_at(source, place))
          col_x = x + i * cell
          if i == digits - 1
            draw_glyph(digit, col_x, y, color, font) # the ones column always shows
          else
            if_ne(digit, 0) { set(started, 1) }
            if_eq(started, 1) { draw_glyph(digit, col_x, y, color, font) }
          end
        end
        nil
      end

      # Draw the single digit held in +digit_var+ (0..9) at (x, y) as one
      # draw_digit node in the named font — the tree keeps "draw one digit here" as a
      # single intent, and the backend decides how to render it (a font lookup, or a
      # fan-out).
      def draw_glyph(digit_var, x, y, color, font)
        ensure_var(digit_var)
        record(Build.draw_digit(Build.var_ref(digit_var), x, y, color, font: font))
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

      # --- tiled-mode text: glyphs drawn as sprites -------------------------------
      #
      # A tiled screen draws from tiles and sprites, not a framebuffer, so there's
      # nowhere for the bitmap draw_text/draw_number to plot pixels. Instead each
      # character becomes a tiny hardware sprite — one 8x8 glyph — that the console
      # composites over the game every frame. Because a sprite is drawn for you each
      # frame, tiled text is declared ONCE (before the game loop, like `sprite`) and
      # then stays; a live number's sprite chooses which digit to show from its value
      # each frame, so it updates itself with nothing to call in the loop.

      # A glyph fits in one 8x8 sprite tile.
      HUD_GLYPH_PX = 8

      # Draw a fixed string as a row of glyph sprites at (x, y), advancing one font
      # cell per character. A space or a character the font lacks draws nothing but
      # still takes its column, so words stay aligned.
      def draw_text_tiled(text, x, y, color, font)
        f = Fonts.get(font)
        text.each_char.with_index do |ch, i|
          next unless f.glyph(ch) # a blank or unknown character: leave the gap, draw nothing

          hud_glyph_object(poses: [glyph_image(font, ch, color)], pose: Build.int(0),
                           x: x + i * f.cell_w, y: y)
        end
        nil
      end

      # Draw a number as glyph sprites. A fixed number is just its right-aligned
      # digits (like draw_text). A live number gets one sprite per digit column, each
      # showing the matching glyph for its place in the value — recomputed every frame
      # from the variable, with leading zeros left blank so it reads naturally.
      def draw_number_tiled(value, x, y, color, digits, font)
        cell = Fonts.get(font).cell_w
        if value.is_a?(Integer)
          text = value.to_s
          pad = [digits - text.length, 0].max # right-align in the field
          return draw_text_tiled(text, x + pad * cell, y, color, font)
        end

        source = hud_number_variable(value)
        poses = [blank_glyph_image] + ("0".."9").map { |d| glyph_image(font, d, color) }
        digits.times do |i|
          place = 10**(digits - 1 - i)
          hud_glyph_object(poses: poses, pose: hud_digit_pose(source, place),
                           x: x + i * cell, y: y)
        end
        nil
      end

      # The variable a live tiled number tracks. A digit column reads it every frame,
      # so it must be a plain variable (a Symbol, or a `var` handle), not a one-off
      # expression — there's no per-frame place to recompute an expression into.
      def hud_number_variable(value)
        name = value.is_a?(Symbol) ? value : (value.node[:name] if value.node.kind == :var_ref)
        return name if name

        raise ArgumentError,
              "On a tiled screen, draw_number follows a variable and updates itself each frame. " \
              "Give it a variable (like :score), not an expression. Store the value in a variable " \
              "first (for example `set :shown, hp - 1`). Then draw that variable."
      end

      # The sprite pose that shows the digit of +source+ at +place+ (1, 10, 100, …).
      # Pose 0 is the blank glyph and poses 1..10 are the digits 0..9, so the value to
      # show is (that digit + 1). Every column but the ones column blanks out while the
      # number hasn't reached its place yet — that's what drops the leading zeros —
      # which is exactly `(source >= place)` (0 or 1) times the digit-plus-one.
      def hud_digit_pose(source, place)
        show = Build.binop(:+, digit_at(source, place), Build.int(1))
        return show if place == 1

        Build.binop(:*, Build.binop(:>=, Build.var_ref(source), Build.int(place)), show)
      end

      # Declare one glyph sprite (an object) at a fixed screen spot and remember it so
      # every frame's repaint draws it, on top of the game. active is always 1 — a HUD
      # glyph is simply always shown.
      def hud_glyph_object(poses:, pose:, x:, y:)
        name = :"__hud#{@sprite_seq += 1}"
        # active is 1 (a HUD glyph is always shown) unless it's declared inside a scene,
        # where scene_gate scopes it to when that scene is active — so a scene's HUD comes
        # and goes with the scene, with nothing to toggle by hand.
        record(Build.object(name, poses: poses, pose: pose,
                                  x: Build.int(x), y: Build.int(y), active: scene_gate(Build.int(1))))
        @hud_objects << name
        name
      end

      # The image name for one glyph of a font in a color — an 8x8 sprite tile with the
      # glyph's lit pixels in that color and everything else transparent. Cached, so a
      # digit reused across columns (or a repeated letter) is built once.
      def glyph_image(font_name, char, color)
        @glyph_images[[font_name, char, color]] ||= begin
          font = Fonts.get(font_name)
          fits_a_glyph_tile!(font_name, font)
          data = Array.new(HUD_GLYPH_PX * HUD_GLYPH_PX, Images::TRANSPARENT_PIXEL)
          font.each_pixel(char.to_s) { |dx, dy| data[(dy * HUD_GLYPH_PX) + dx] = color }
          name = :"__glyph#{@glyph_images.size}"
          define_pixel_image(name, width: HUD_GLYPH_PX, height: HUD_GLYPH_PX,
                                   data: data, transparent: Images::TRANSPARENT_PIXEL)
          name
        end
      end

      # The all-transparent glyph a digit column shows for a leading zero.
      def blank_glyph_image
        @blank_glyph_image ||= begin
          data = Array.new(HUD_GLYPH_PX * HUD_GLYPH_PX, Images::TRANSPARENT_PIXEL)
          define_pixel_image(:__glyph_blank, width: HUD_GLYPH_PX, height: HUD_GLYPH_PX,
                                             data: data, transparent: Images::TRANSPARENT_PIXEL)
          :__glyph_blank
        end
      end

      # A glyph must fit one 8x8 sprite tile in tiled mode. The built-in :default (5x7)
      # and :tiny (3x5) do; a taller/wider custom font would need a bigger sprite, which
      # isn't wired up yet — so say so plainly rather than clip the glyph.
      def fits_a_glyph_tile!(font_name, font)
        return if font.cell_w <= HUD_GLYPH_PX && font.height <= HUD_GLYPH_PX

        raise ArgumentError,
              "On a tiled screen, the console draws text as #{HUD_GLYPH_PX}x#{HUD_GLYPH_PX} sprite glyphs. " \
              "Font :#{font_name} is #{font.cell_w}x#{font.height} per character. That is too big for one glyph tile. " \
              "Use a smaller font (the built-in :default and :tiny fit), or draw this text on a `screen :bitmap`."
      end

      # Tiled text is declared once and redrawn for you every frame, so it belongs at
      # the top level (before game_loop), not inside the loop — declared inside, it
      # would be re-added every frame and never make it into the frame's sprite list.
      # Point at the fix rather than let a HUD silently fail to appear.
      def require_hud_declared_once!(verb)
        return if @container_stack.length == 1 # only the program itself is open
        return if @building_scene # a scene declares its own HUD in its body (built once, off the loop)

        raise ArgumentError,
              "Call #{verb} once, above your game_loop. Do not call it inside the loop. " \
              "On a tiled screen, the console redraws the text every frame (like a sprite). " \
              "You declare it once and it stays. If it shows a value that changes, pass the variable and it updates itself."
      end
    end
  end
end
