# frozen_string_literal: true

module RubyGBA
  class Builder
    # The bitmap drawing verbs: pick a screen mode, then put color on the screen —
    # single pixels, filled rectangles (fixed or run-time positioned), a whole-screen
    # clear. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # It includes Constants for the hardware register values behind the friendly
    # names — the MODE_*/BG*_ENABLE bits in SCREEN_MODES and the SCREEN_* bounds in
    # validate_coords! (a concern doesn't inherit Builder's own Constants include).
    module Drawing
      include Constants

      # Friendly screen mode presets — the names {#screen} accepts. The tear-proof
      # double-buffered screen isn't a separate name here: it's `screen :bitmap,
      # tear_free: true` (which selects Mode 4 with an auto-built palette).
      SCREEN_MODES = {
        bitmap: MODE_3 | BG2_ENABLE, # 240x160 pixel canvas, 15-bit direct color
        tiled:  MODE_0 | BG0_ENABLE, # 4 regular tile/sprite background layers (most games)
        affine: MODE_2 | BG2_ENABLE, # 2 rotatable/scalable background layers
      }.freeze

      # Choose what kind of screen you're drawing on.
      #
      # @param mode [Symbol, Integer] a friendly name or raw REG_DISPCNT value
      #
      # @example Friendly
      #   screen :bitmap          # a pixel canvas (MODE_3 | BG2_ENABLE)
      #   screen :tiled           # tile/sprite layers (MODE_0 | BG0_ENABLE)
      #
      # @example Raw (full control)
      #   screen MODE_3 | BG2_ENABLE | OBJ_ENABLE
      #
      # Pass +tear_free: true+ to make `screen :bitmap` tear-proof: the framework
      # draws each frame to a hidden screen and shows it all at once, so the picture
      # can never tear no matter how much you draw. It costs some color range (a
      # 256-color palette built automatically from the colors you use), so it's
      # opt-in; plain `screen :bitmap` stays direct-color. (Under the hood this is
      # double buffering, which the IR and backend call "buffered".)
      #
      # @example Tear-proof
      #   screen :bitmap, tear_free: true
      def screen(mode, tear_free: false)
        case mode
        when Symbol
          unless SCREEN_MODES.key?(mode)
            raise ArgumentError, "unknown screen mode: #{mode}. Known: #{SCREEN_MODES.keys.join(', ')}"
          end
        when Integer
          # a raw REG_DISPCNT value — passed through untouched
        else
          raise ArgumentError,
                "screen needs a Symbol (a name like :bitmap) or an Integer (a raw register value). " \
                "Got #{mode.class}."
        end

        if tear_free && mode != :bitmap
          raise ArgumentError,
                "tear_free: true works only with `screen :bitmap`. It enables the tear-proof " \
                "double-buffered screen. #{mode.inspect} does not support it."
        end

        # Remember the mode by name so `sprite` knows which kind to make (a bitmap
        # screen draws sprites in software; a tiled screen uses the console's sprite
        # hardware). A raw register value doesn't map to a friendly name, so it leaves
        # the mode unnamed.
        @screen_mode = mode if mode.is_a?(Symbol)
        record(Build.screen(mode, buffered: tear_free))
      end

      # Draw a single pixel in bitmap mode (MODE_3).
      # Writes a 15-bit color to VRAM at the (x, y) offset.
      #
      # @param x [Integer] horizontal position (0-239)
      # @param y [Integer] vertical position (0-159)
      # @param c [Symbol, String, Integer] color (see {Color.resolve})
      def pixel(x, y, c)
        validate_coords!(x, y)
        record(Build.pixel(x, y, c))
      end

      # Fill a rectangle in bitmap mode (MODE_3).
      #
      # @param x [Integer] left edge (0-239)
      # @param y [Integer] top edge (0-159)
      # @param w [Integer] width in pixels
      # @param h [Integer] height in pixels
      # @param c [Symbol, String, Integer] fill color
      def fill_rect(x, y, w, h, c)
        record(Build.fill_rect(x, y, w, h, c))
      end

      # Clear the entire screen to a solid color.
      # Much faster than pixel-by-pixel: one DMA transfer fills all of VRAM.
      #
      # @param c [Symbol, String, Integer] fill color
      def clear_screen(c)
        record(Build.clear_screen(c))
      end

      # --- the camera ---

      # Move the visible window over the whole picture. `camera 0, 0` shows it as
      # drawn; any other offset slides everything on screen at once.
      #
      # Nothing is redrawn — the picture stays where it is and the window moves — so
      # this costs the same however much is on screen. Where the window falls outside
      # the picture there is nothing to show, and the backdrop appears along that edge,
      # which is why a shake keeps its offset small.
      #
      # @param x [Symbol, Integer, Value] the window's left edge, in pixels
      # @param y [Symbol, Integer, Value] the window's top edge, in pixels
      def camera(x, y)
        record(Build.camera(x: Value.node_for(x), y: Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
      end

      # The colors a fade can go to. Black and white are what the display can blend
      # the whole screen toward without redrawing anything.
      FADE_COLORS = %i[black white].freeze

      # Fade the whole screen toward black or white.
      #
      # `amount` is how far, from 0 (the picture as drawn) to 100 (nothing left but
      # that color). Nothing is redrawn — the picture is all still there, and comes
      # back untouched when the fade lifts — so this costs the same however much is on
      # screen, and it works on either kind of screen.
      #
      #   fade :black             # black out
      #   fade :black, 0          # back to normal
      #   fade :white, 50         # halfway to white
      #
      # It sets the level at the moment you call it. To fade over time, move a
      # variable and pass it: this is the primitive `fade_in` / `fade_out` sit on.
      #
      #   level = var :level, 0
      #   game_loop do
      #     level.approach 100, 4   # walk it up over a few frames
      #     fade :black, level
      #   end
      #
      # @param toward [Symbol] :black or :white
      # @param amount [Symbol, Integer, Value] how far, 0 to 100
      def fade(toward, amount = 100)
        unless FADE_COLORS.include?(toward)
          raise ArgumentError,
                "fade goes to :black or :white. You gave #{toward.inspect}."
        end
        if amount.is_a?(Integer) && !(0..100).cover?(amount)
          raise ArgumentError,
                "fade's amount is how far to go, from 0 to 100. You gave #{amount}."
        end

        record(Build.fade(toward: toward, amount: Value.node_for(amount)))
        ensure_var(amount)
      end

      # Fill a rectangle at a fixed position and size.
      #
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param w [Integer] width in pixels (must be even for the fast fill)
      # @param h [Integer] height in pixels
      # @param c [Symbol, String, Integer] fill color
      def dma_fill_rect(x, y, w, h, c)
        record(Build.dma_fill_rect(x, y, w, h, c))
      end

      # Draw a filled rectangle at a position, and to a height, the game can work out
      # as it runs. The position and the height may each be a variable, an expression,
      # or a plain number; only the width is settled while building, and it must be
      # even (for the fast fill).
      #
      # A height the game computes is what a bar or a column needs — a health meter
      # that shrinks, a wall column in a first-person view, a tower that grows:
      #
      #   draw_rect_at 8, 8, 40, health, :red     # a meter as tall as the health left
      #
      # A height of zero or less draws nothing, so a bar can empty completely without
      # a test around it.
      #
      # @param x_pos [Symbol, Integer, Value] x position
      # @param y_pos [Symbol, Integer, Value] y position
      # @param w [Integer] width in pixels (must be even, settled while building)
      # @param h [Symbol, Integer, Value] height in pixels
      # @param c [Symbol, String, Integer] fill color
      def draw_rect_at(x_pos, y_pos, w, h, c)
        record(Build.draw_rect_at(Value.node_for(x_pos), Value.node_for(y_pos), w, Value.node_for(h), c))
        ensure_var(x_pos)
        ensure_var(y_pos)
        ensure_var(h)
      end

      # Lay out a board of equal cells and get a handle for painting them one at a
      # time. The game then works in cell coordinates (0, 1, 2 …) — set_cell and
      # clear_cell handle the pixel arithmetic — so a tile game reads as a tile game
      # and each step touches only the cells that changed. See {Grid}.
      #
      #   board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
      #   board.set_cell   x, y, :white   # paint one cell
      #   board.clear_cell x, y            # return it to the background (:black)
      #
      # @param name [Symbol] the board's name
      # @param cols [Integer] columns across
      # @param rows [Integer] rows down
      # @param cell [Integer] a cell's size in pixels (even)
      # @param over [Symbol, String, Integer] the background color a cleared cell shows
      # @return [Grid] a handle with set_cell / clear_cell
      def grid(name, cols:, rows:, cell:, over:)
        Grid.new(self, name: name, cols: cols, rows: rows, cell: cell, over: over)
      end

      private

      def validate_coords!(x, y)
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{SCREEN_WIDTH - 1}." unless (0...SCREEN_WIDTH).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{SCREEN_HEIGHT - 1}." unless (0...SCREEN_HEIGHT).cover?(y)
      end
    end
  end
end
