# frozen_string_literal: true

module RubyGBA
  class Builder
    # The bitmap drawing verbs: pick a display mode, then put color on the screen —
    # single pixels, filled rectangles (fixed or run-time positioned), a whole-screen
    # clear. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # It includes Constants for the hardware register values behind the friendly
    # names — the MODE_*/BG*_ENABLE bits in DISPLAY_MODES and the SCREEN_* bounds in
    # validate_coords! (a concern doesn't inherit Builder's own Constants include).
    module Drawing
      include Constants

      # Friendly screen mode presets — the names {#screen} accepts. The tear-proof
      # double-buffered screen isn't a separate name here: it's `screen :bitmap,
      # tear_free: true` (which selects Mode 4 with an auto-built palette).
      DISPLAY_MODES = {
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
          unless DISPLAY_MODES.key?(mode)
            raise ArgumentError, "unknown screen mode: #{mode}. Known: #{DISPLAY_MODES.keys.join(', ')}"
          end
        when Integer
          # a raw REG_DISPCNT value — passed through untouched
        else
          raise ArgumentError, "expected Symbol or Integer, got #{mode.class}"
        end

        if tear_free && mode != :bitmap
          raise ArgumentError,
                "tear_free: true is only for `screen :bitmap` — it turns on the tear-proof " \
                "double-buffered screen; #{mode.inspect} doesn't support it"
        end

        record(Build.display(mode, buffered: tear_free))
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

      # Draw a filled rectangle at a position determined at run time.
      # Positions can be variables (Symbol) or constants (Integer); the size is a
      # build-time constant and the width must be even (for the fast fill).
      #
      # @param x_pos [Symbol, Integer] x position (variable or constant)
      # @param y_pos [Symbol, Integer] y position (variable or constant)
      # @param w [Integer] width in pixels (must be even, build-time constant)
      # @param h [Integer] height in pixels (build-time constant)
      # @param c [Symbol, String, Integer] fill color
      def draw_rect_at(x_pos, y_pos, w, h, c)
        record(Build.draw_rect_at(Value.node_for(x_pos), Value.node_for(y_pos), w, h, c))
        ensure_var(x_pos)
        ensure_var(y_pos)
      end

      private

      def validate_coords!(x, y)
        raise ArgumentError, "x=#{x} out of range (0-#{SCREEN_WIDTH - 1})" unless (0...SCREEN_WIDTH).cover?(x)
        raise ArgumentError, "y=#{y} out of range (0-#{SCREEN_HEIGHT - 1})" unless (0...SCREEN_HEIGHT).cover?(y)
      end
    end
  end
end
