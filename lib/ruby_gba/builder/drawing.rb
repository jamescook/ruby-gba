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
        rotozoom: MODE_2 | BG2_ENABLE, # 2 rotatable/scalable background layers
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
      #
      # Pass +colors:+ to say which colors the screen shows, instead of letting the
      # framework work them out from the ones you name. You want this only when your
      # pictures come from somewhere that already decided — art imported from another
      # game or a paint program, whose pixels are numbers that pick out of ITS table.
      # Give the colors in that table's order and the pictures line up. Everything
      # else is unchanged: you still write color names, and you never write a slot
      # number. A color you draw with that is not in the list is a friendly error.
      #
      # @example Colors that came with the art
      #   screen :bitmap, tear_free: true, colors: imported.colors
      def screen(mode, tear_free: false, colors: nil)
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
        record(Build.screen(mode, buffered: tear_free, colors: given_colors(colors, tear_free)))
      end

      # Everything the block draws stays inside this part of the screen. What falls outside is
      # CUT OFF rather than covered up: those pixels are never worked out, so the drawing costs
      # what fits and not what was asked for.
      #
      #   inside 0, 0, 240, 128 do
      #     ...the game...
      #   end
      #   draw_the_status_bar   # ...and this is outside it, so it draws
      #
      # This is what a game with a panel wants — a strip of world with a row of numbers under
      # it, a map beside it, a letterboxed cut scene. Without it the world is drawn over the
      # whole screen and the panel painted on top, and everything under the panel was drawn for
      # nothing. In a first-person view, where a near wall is drawn taller than the screen, that
      # is most of a near wall.
      #
      # It clips; it does not move. A pixel drawn at (10, 10) is at (10, 10) whatever area is in
      # force — so an area can be put round drawing that already works, and only the parts that
      # were falling outside change.
      #
      # The edges are settled while you write the program, because where a panel goes is part of
      # how a screen is laid out rather than something a game works out as it runs. Areas do not
      # nest inside each other.
      #
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param w [Integer] width in pixels
      # @param h [Integer] height in pixels
      def inside(x, y, w, h, &block)
        raise ArgumentError, "inside needs a block: inside(x, y, w, h) { ... }" unless block

        [["x", x], ["y", y], ["w", w], ["h", h]].each do |name, value|
          next if value.is_a?(Integer)

          raise ArgumentError,
                "`inside` needs edges settled while you build. Got #{name}: #{value.inspect}. " \
                "Where a part of the screen is belongs to how the screen is laid out, not to " \
                "something the game works out as it runs."
        end
        if @inside_area
          raise ArgumentError,
                "`inside` cannot go inside another `inside`. One area is in force at a time. " \
                "Close the one you are in, or give this one the edges you want."
        end

        @inside_area = [x, y, w, h]
        push_container(Build.inside(x, y, w, h)) { run_block(&block) }
      ensure
        @inside_area = nil
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
      # `under:` puts the fade at a place in the stack instead of over the whole
      # picture: it names a layer, and that layer and everything in front of it are
      # left alone. Fade the game out and keep the score showing:
      #
      #   layers :world, :actors, :ui
      #   fade :black, 100, under: :ui
      #
      # @param toward [Symbol] :black or :white
      # @param amount [Symbol, Integer, Value] how far, 0 to 100
      # @param under [Symbol, nil] a layer this fade sits under, or nil for the whole screen
      def fade(toward, amount = 100, under: nil)
        unless FADE_COLORS.include?(toward)
          raise ArgumentError,
                "fade goes to :black or :white. You gave #{toward.inspect}."
        end
        fixed = Value.fixed_number(amount)
        if fixed && !(0..100).cover?(fixed)
          raise ArgumentError,
                "fade's amount is how far to go, from 0 to 100. You gave #{fixed}."
        end
        check_effect_layer!(:fade, under) if under

        record(Build.fade(toward: toward, amount: Value.node_for(amount), under: under))
        ensure_var(amount)
      end

      # Tint the whole screen toward a color — red for damage, blue for cold water,
      # orange for a sunset. `fade`'s sibling, for the colors a fade cannot reach.
      #
      # `amount` is how far, from 0 (the picture as drawn) to 100 (nothing left but
      # that color). Nothing is redrawn, so the picture is all still there and comes
      # back untouched when the tint lifts.
      #
      #   tint :red               # everything red
      #   tint :red, 0            # back to normal
      #   tint :orange, 30        # a warm wash over the picture
      #
      # Like `fade` it sets the level where you call it, so tinting over time is a
      # variable moved a little each frame:
      #
      #   hurt = var :hurt, 0
      #   game_loop do
      #     hurt.approach 0, 6      # ease it back off
      #     tint :red, hurt
      #   end
      #
      # @param color [Symbol, String, Integer] the color to move the picture toward
      # @param amount [Symbol, Integer, Value] how far, 0 to 100
      def tint(color, amount = 100)
        fixed = Value.fixed_number(amount)
        if fixed && !(0..100).cover?(fixed)
          raise ArgumentError,
                "tint's amount is how far to go, from 0 to 100. You gave #{fixed}."
        end

        record(Build.tint(color: Color.resolve(color), amount: Value.node_for(amount)))
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

      # Draw ONE COLUMN of a picture, stretched to a height the game works out.
      #
      # This is what a first-person view is made of. For each strip across the screen a
      # game works out how far away the wall is, turns that into a height, and draws a
      # column of a wall picture that tall — near walls tall, far walls short. Do that
      # across the screen and a flat grid of cells looks like rooms you can walk through.
      #
      #   draw_column_at :bricks, slice: ray_hit, x: col * 2, top: top, height: tall
      #
      # +slice+ picks the column of the picture (which part of the wall you are looking
      # at); +x+ is where it lands on screen; +top+ and +height+ are where it starts and
      # how tall it is. All four can be worked out as the game runs.
      #
      # A height of zero or less draws nothing, and anything off the top or bottom of the
      # screen is clipped, so a wall you are nose-to-nose with needs no test around it.
      #
      # +width+ is how many pixels ACROSS the strip is, 1 by default. A view drawing
      # strips wider than a pixel wants this rather than a loop of its own: the whole
      # strip shows the same picture column at the same height, so one walk down the
      # screen fills all of it. Calling this once per pixel instead works out the same
      # answer that many times over.
      #
      # @param name [Symbol] a picture defined with {#image}
      # @param slice [Symbol, Integer, Value] which column of the picture
      # @param x [Symbol, Integer, Value] where it lands on screen
      # @param top [Symbol, Integer, Value] the screen row it starts on
      # @param height [Symbol, Integer, Value] how tall to stretch it
      # @param width [Integer] how many pixels across, settled while building
      def draw_column_at(name, slice:, x:, top:, height:, width: 1, estimate: nil)
        unless @images.key?(name)
          raise ArgumentError,
                "draw_column_at needs a picture. There is no image :#{name}. " \
                "Define it with `image :#{name} do ... end` first."
        end
        unless width.is_a?(Integer) && width.positive?
          raise ArgumentError,
                "draw_column_at needs a `width:` of 1 or more, settled while you build. " \
                "Got #{width.inspect}. A strip's width is a property of the view, not " \
                "something the game works out as it runs."
        end

        record(Build.draw_column_at(name, Value.node_for(slice), Value.node_for(x),
                                    Value.node_for(top), Value.node_for(height), width: width,
                                    usually: stretched_usually(height, estimate, "column")))
        [slice, x, top, height].each { |operand| ensure_var(operand) }
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
      # @param estimate [Hash, nil] `{ usually: N }` — how tall it normally is, for the
      #   estimate only. Changes nothing about how the game runs; see {#draw_column_at}.
      def draw_rect_at(x_pos, y_pos, w, h, c, estimate: nil)
        record(Build.draw_rect_at(Value.node_for(x_pos), Value.node_for(y_pos),
                                  Value.node_for(w), Value.node_for(h), c,
                                  usually: stretched_usually(h, estimate, "rectangle")))
        ensure_var(x_pos)
        ensure_var(y_pos)
        ensure_var(w)
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

      # What `estimate: { usually: N }` said about how tall this shape normally is — a stretched
      # column or a rectangle, which take the hint for the same reason and refuse it for the
      # same one. Only a height the game works out can be told: one written in the program is
      # already known, and saying it twice invites the two to disagree.
      def stretched_usually(height, estimate, shape)
        return nil if estimate.nil?

        if height.is_a?(Integer)
          raise ArgumentError,
                "`estimate:` belongs on a #{shape} whose height the game works out. This one is " \
                "#{height} rows tall every time, so the estimate already knows. Remove it."
        end

        usual_length(estimate, SCREEN_HEIGHT)
      end

      # The colors a screen was told to show, resolved the same way every draw verb
      # resolves one, so a name, a hex string and a raw value all mean the same thing
      # here as they do there.
      def given_colors(colors, tear_free)
        return nil if colors.nil?

        unless colors.is_a?(Array) && !colors.empty?
          raise ArgumentError, "screen colors: needs a list of colors, like [:black, :red, ...]. Got #{colors.inspect}."
        end

        unless tear_free
          raise ArgumentError,
                "screen colors: works only with `screen :bitmap, tear_free: true`. A plain bitmap " \
                "screen holds a full color in every pixel, so it has no table to fill in."
        end

        if colors.length > IR::Palette::CAPACITY
          raise ArgumentError,
                "screen colors: got #{colors.length} colors, and the screen shows at most " \
                "#{IR::Palette::CAPACITY}. Give a shorter list."
        end

        colors.map { |spec| Color.resolve(spec) }
      end

      def validate_coords!(x, y)
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{SCREEN_WIDTH - 1}." unless (0...SCREEN_WIDTH).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{SCREEN_HEIGHT - 1}." unless (0...SCREEN_HEIGHT).cover?(y)
      end
    end
  end
end
