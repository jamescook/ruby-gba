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

      # The hidden variables the shake runs on, and the routine that drives it. Named
      # with the framework's underscore prefix so they never collide with a game's own.
      SHAKE_LEFT = :__shake_left     # frames of shaking still to run (-1 = settled)
      SHAKE_POWER = :__shake_power   # how far to move, in pixels
      SHAKE_DIR = :__shake_dir       # +1 / -1, flipped every frame to make the jitter
      SHAKE_OFFSET = :__shake_offset # this frame's offset, power * dir
      SHAKE_TICK = :__shake_tick

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

      # Shake the screen — the impact effect for a hit, an explosion, a life lost.
      #
      # Say how hard and how long, and the framework does the rest: it jitters the
      # camera for you every frame from here on, then puts the picture back exactly
      # where it was. You call this once, at the moment of impact, and nothing else.
      #
      #   shake_screen intensity: 3, frames: 8      # eight frames of shaking
      #   shake_screen intensity: 3, duration: 0.2  # the same, said in seconds
      #
      # Calling it again while a shake runs restarts it, so repeated hits keep shaking
      # rather than queueing up.
      #
      # @param intensity [Integer] how far the picture moves, in pixels
      # @param frames [Integer, nil] how long to shake, in frames
      # @param duration [Numeric, nil] how long to shake, in seconds (instead of frames)
      def shake_screen(intensity: 2, frames: nil, duration: nil)
        count = shake_length!(frames, duration)
        unless intensity.is_a?(Integer) && intensity.positive?
          raise ArgumentError,
                "shake_screen needs a positive whole number for intensity. " \
                "You gave #{intensity.inspect}."
        end

        install_shake!
        set SHAKE_LEFT, count
        set SHAKE_POWER, intensity
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

      # How many frames to shake for, from whichever unit the caller used.
      def shake_length!(frames, duration)
        if frames && duration
          raise ArgumentError, "shake_screen takes frames: or duration:, not both."
        end

        if duration
          unless duration.is_a?(Numeric) && duration.positive? && to_frames(duration, :seconds).positive?
            raise ArgumentError,
                  "shake_screen needs a positive duration in seconds. You gave #{duration.inspect}."
          end
          return to_frames(duration, :seconds)
        end

        frames ||= 8 # a short, punchy default
        unless frames.is_a?(Integer) && frames.positive?
          raise ArgumentError,
                "shake_screen needs a positive whole number of frames. You gave #{frames.inspect}."
        end
        frames
      end

      # Declare the shake routine, once, however many places shake the screen.
      #
      # The routine runs every frame (see Builder#finalize_shake_tick) and owns the
      # camera while a shake lasts: it flips the direction, moves the picture that far,
      # and counts down. On the frame the count reaches zero it puts the camera back to
      # where it was and takes the counter negative, so a settled game does no work at
      # all — the picture is left alone until the next impact.
      def install_shake!
        return if @shake_installed

        @shake_installed = true
        [SHAKE_LEFT, SHAKE_POWER, SHAKE_DIR, SHAKE_OFFSET].each { |name| ensure_var(name) }
        at_boot(Build.set(SHAKE_LEFT, Build.int(-1))) # settled: nothing to undo yet
        at_boot(Build.set(SHAKE_DIR, Build.int(1)))

        left = handle_for(SHAKE_LEFT)
        power = handle_for(SHAKE_POWER)
        direction = handle_for(SHAKE_DIR)

        func(SHAKE_TICK) do
          # The settle comes FIRST so the last shaking frame is really shown: the
          # branch below takes the count to zero, and only the NEXT frame puts the
          # picture back.
          (left == 0).then do
            camera 0, 0
            left.sub 1 # -> -1, so this never runs again until the next shake
          end
          (left > 0).then do
            direction.flip
            set SHAKE_OFFSET, power * direction
            camera SHAKE_OFFSET, SHAKE_OFFSET
            left.sub 1
          end
        end
        shake_each_frame
      end

      def handle_for(name)
        Value.new(self, Build.var_ref(name), name: name)
      end

      def validate_coords!(x, y)
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{SCREEN_WIDTH - 1}." unless (0...SCREEN_WIDTH).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{SCREEN_HEIGHT - 1}." unless (0...SCREEN_HEIGHT).cover?(y)
      end
    end
  end
end
