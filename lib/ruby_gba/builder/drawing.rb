# frozen_string_literal: true

module RubyGBA
  class Builder
    # The bitmap drawing verbs: pick a screen mode, then put color on the screen —
    # single pixels, filled rectangles (fixed or run-time positioned), a whole-screen
    # clear. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # It includes Console::Hardware for the hardware register values behind the friendly
    # names — the MODE_*/BG*_ENABLE bits in SCREEN_MODES and the SCREEN_* bounds in
    # validate_coords! (a concern doesn't inherit Builder's own Console::Hardware include).
    module Drawing
      include Console::Hardware

      # Friendly screen mode presets — the names {#screen} accepts. The tear-proof
      # double-buffered screen isn't a separate name here: it's `screen :bitmap,
      # tear_free: true` (which selects Mode 4 with an auto-built palette).
      SCREEN_MODES = {
        bitmap: MODE_3 | BG2_ENABLE, # 240x160 pixel canvas, 15-bit direct color
        tiled:  MODE_0 | BG0_ENABLE, # tile/sprite background layers (most games)
        rotozoom: MODE_2 | BG2_ENABLE, # one background that turns and resizes, and no scrolling ones
      }.freeze

      # Choose what kind of screen you're drawing on.
      #
      # @param mode [Symbol, Integer] a friendly name or raw REG_DISPCNT value
      #
      # @example Friendly
      #   screen :bitmap          # a pixel canvas (MODE_3 | BG2_ENABLE)
      #   screen :tiled           # tile/sprite layers
      #
      # HOW MANY TILE LAYERS `screen :tiled` HAS IS NOT FIXED, and nothing in a program
      # says which arrangement it wants. The console lays its tile layers out two ways:
      # four that scroll, or two that scroll plus one that turns and resizes. A game gets
      # the second exactly when it turns a background (`background(...).rotate` /
      # `.scale`), because turning one IS asking for it — so the build reads the
      # arrangement off what was declared rather than off a name written here. Declaring
      # more scrolling layers than the arrangement holds is a friendly error naming both
      # counts, never a layer quietly left undrawn. See {Backends::GBA::Drawing#tiled_dispcnt}.
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
        @tear_free = tear_free
        record(Build.screen(mode, buffered: tear_free, colors: resolve_screen_colors(colors, tear_free)))
      end

      # HOW MANY PICTURES THIS SCREEN KEEPS. A tear-free screen keeps two and shows
      # them in turn, so a change drawn once reaches only one of them; a plain screen
      # keeps one, so a change drawn once is done. This is the number of times a
      # picture that is drawn and then left alone has to be painted (Packs::KeepShowing).
      def screen_pages = @tear_free ? 2 : 1

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
        record(Build.camera(x: DSL::Value.node_for(x), y: DSL::Value.node_for(y)))
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
      #     level.approach! 100, 4   # walk it up over a few frames
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
      # `inside:` holds the fade to a rectangle of the screen, `[x, y, width, height]`, and
      # leaves the rest as drawn; `outside:` fades everything but the rectangle. Fade the view
      # and keep the status bar under it, or dim a game behind a pause box:
      #
      #   fade :black, 100, inside: [0, 0, 240, 128]
      #   fade :black, 50, outside: [60, 40, 120, 80]
      #
      # The display does it with a window — a rectangle it is told about — and its darkening
      # switched on in one part and off in the other, so it is as free as a whole-screen fade.
      #
      # @param toward [Symbol] :black or :white
      # @param amount [Symbol, Integer, Float, Value] how far, 0 to 100 (a fraction asks for finer steps)
      # @param under [Symbol, nil] a layer this fade sits under, or nil for the whole screen
      # @param inside [Array<Integer>, nil] the rectangle the fade is held to
      # @param outside [Array<Integer>, nil] the rectangle the fade leaves alone
      def fade(toward, amount = 100, under: nil, inside: nil, outside: nil)
        unless FADE_COLORS.include?(toward)
          raise ArgumentError,
                "fade goes to :black or :white. You gave #{toward.inspect}."
        end
        node, bits = effect_amount(:fade, amount)
        reaches, area = fade_area(under, inside, outside)
        check_effect_layer!(:fade, under) if under

        record(Build.fade(toward: toward, amount: node, under: under, fraction_bits: bits, reaches: reaches,
                          area: area))
        ensure_var(amount)
      end

      private

      # Which side of a rectangle a fade reaches, and the rectangle as the display's window
      # takes it: [left, top, right, bottom], the right and bottom one past the last column and
      # row, clipped to the screen. A rectangle wholly off the screen, or of no width or
      # height, holds nothing. Nil and nil for a fade over the whole screen.
      def fade_area(under, inside, outside)
        return [nil, nil] if inside.nil? && outside.nil?

        refuse_fade_area_beside!(under, inside, outside)
        reaches, rect = inside ? [:inside, inside] : [:outside, outside]
        refuse_fade_area_shape!(reaches, rect)
        x, y, w, h = rect
        left, right = [x, x + w].map { |edge| edge.clamp(0, Console::Hardware::SCREEN_WIDTH) }
        top, bottom = [y, y + h].map { |edge| edge.clamp(0, Console::Hardware::SCREEN_HEIGHT) }
        empty = left >= right || top >= bottom
        [reaches, empty ? [0, 0, 0, 0] : [left, top, right, bottom]]
      end

      def refuse_fade_area_beside!(under, inside, outside)
        if inside && outside
          raise ArgumentError, "fade takes `inside:` or `outside:`, not both. Give the one rectangle the fade " \
                               "is held to (`inside:`) or the one it leaves alone (`outside:`)."
        end
        return unless under

        raise ArgumentError, "fade takes `under:` or a rectangle, not both. `under:` places the fade in the " \
                             "stack, and `inside:` or `outside:` holds it to part of the screen. To fix this, " \
                             "give one of them."
      end

      def refuse_fade_area_shape!(word, rect)
        return if rect.is_a?(Array) && rect.size == 4 && rect.all?(Integer)

        raise ArgumentError, "fade `#{word}:` takes a rectangle as four whole numbers you write: " \
                             "[x, y, width, height], in pixels. You gave #{rect.inspect}."
      end

      public

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
      #     hurt.approach! 0, 6      # ease it back off
      #     tint :red, hurt
      #   end
      #
      # @param color [Symbol, String, Integer] the color to move the picture toward
      # @param amount [Symbol, Integer, Float, Value] how far, 0 to 100 (a fraction asks for finer steps)
      def tint(color, amount = 100)
        node, bits = effect_amount(:tint, amount)
        record(Build.tint(color: Graphics::Color.resolve(color), amount: node, fraction_bits: bits))
        ensure_var(amount)
      end

      # Show the whole screen in flat blocks — the pixelate effect of a scene change, a
      # hit, a dream, a teleport.
      #
      # `size` is how many pixels a block is each way: 1 is the picture as drawn, 8 is
      # blocks of eight by eight, and 16 is the biggest the console draws. Nothing is
      # redrawn — the console does it as it draws, so the picture is all still there and
      # comes back untouched — and it costs the same however much is on screen.
      #
      #   pixelate 8              # big blocks
      #   pixelate 1              # back to normal
      #
      # It sets the size where you call it, so pixelating over time is a variable moved
      # a little each frame:
      #
      #   blocks = var :blocks, 1
      #   game_loop do
      #     blocks.approach! 16, 1
      #     pixelate blocks
      #   end
      #
      # `under:` leaves part of the picture as drawn: it names a layer, and that layer and
      # everything in front of it stay sharp. Pixelate the game and keep the score readable:
      #
      #   layers :world, :actors, :ui
      #   pixelate 8, under: :ui
      #
      # A game says one place, and every `pixelate` in it says the same one.
      #
      # @param size [Symbol, Integer, Value] how many pixels a block is each way, 1 to 16
      # @param under [Symbol, nil] a layer left as drawn with everything in front of it, or nil for the whole screen
      def pixelate(size, under: nil)
        refuse_unusable_block_size!(size)
        check_effect_layer!(:pixelate, under) if under
        refuse_second_pixelate_place!(under)

        record(Build.pixelate(size: DSL::Value.node_for(size), under: under))
        ensure_var(size)
      end

      # A light: the picture as drawn inside a circle, and darkened everywhere outside it.
      # A lantern in a cave, a torch in a dungeon, a searchlight sweeping a yard. Declare it
      # once, where it starts, and move it with the handle it hands back:
      #
      #   light = spotlight at: [120, 80], radius: 40, dark: 75
      #   game_loop do
      #     light.move_to hero.x + 8, hero.y + 8
      #   end
      #
      # `at:` is where the middle of the light starts, in screen pixels, `radius:` how far it
      # reaches, and `dark:` how dark the rest of the picture is, 0 (as drawn) to 100 (black).
      # All three are where it STARTS, applied once at power-on, the way `var` takes its
      # starting value; the handle's `x`, `y`, `radius` and `dark` are what the game changes.
      #
      # Nothing is redrawn. The console darkens the picture as it draws it, and is told
      # where the circle is one row at a time, so a light costs the same however much is on
      # screen: working its edge out for each row, in the gap before every frame.
      #
      # `spotlight` with nothing after it hands back the game's light, which is how anything
      # that works on the light finds it — an `iris_out`, a routine in another file. A game
      # with no light yet gets one that reaches past every edge of the screen and darkens
      # nothing, so the picture is as drawn until something moves it.
      #
      # @param at [Array(Integer, Integer)] where the middle of the light starts, in screen pixels
      # @param radius [Integer] how far it reaches from its middle, in pixels
      # @param dark [Integer] how dark the picture is outside it, 0 to 100
      # @return [DSL::Spotlight]
      def spotlight(at: nil, radius: nil, dark: nil)
        said = !(at.nil? && radius.nil? && dark.nil?)
        return @spotlight if @spotlight && !said

        refuse_second_spotlight!
        refuse_spotlight_off_tiles!
        at ||= [Console::Hardware::SCREEN_WIDTH / 2, Console::Hardware::SCREEN_HEIGHT / 2]
        refuse_spotlight_with_no_radius! if said && radius.nil?
        radius ||= Spotlights::LARGEST
        dark ||= said ? Spotlights::DARK_UNSAID : 0
        refuse_spotlight_start!(at, radius, dark)

        light = DSL::Spotlight.new(x: var(Spotlights::X, at[0]), y: var(Spotlights::Y, at[1]),
                                   radius: var(Spotlights::RADIUS, radius), dark: var(Spotlights::DARK, dark))
        record(Spotlights.shade_node(self, light))
        @spotlight_unsaid = !said
        @spotlight = light
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

        record(Build.draw_column_at(name, DSL::Value.node_for(slice), DSL::Value.node_for(x),
                                    DSL::Value.node_for(top), DSL::Value.node_for(height), width: width,
                                    usually: usual_stretch_height(height, estimate, "column")))
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
        record(Build.draw_rect_at(DSL::Value.node_for(x_pos), DSL::Value.node_for(y_pos),
                                  DSL::Value.node_for(w), DSL::Value.node_for(h), c,
                                  usually: usual_stretch_height(h, estimate, "rectangle")))
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
        DSL::Grid.new(self, name: name, cols: cols, rows: rows, cell: cell, over: over)
      end

      private

      # A block is a whole number of pixels, and the console has sizes from one pixel, which
      # is the picture as drawn, to sixteen. A size written in the program outside those is
      # a slip worth saying; one the game works out is held to them as it runs. A number
      # that holds a fraction keeps it in its low bits, so read as a size it would be
      # thousands of pixels.
      def refuse_unusable_block_size!(size)
        largest = IR::Backends::Blocks::LARGEST
        if DSL::Fraction.bits_of(size)
          raise ArgumentError,
                "pixelate's size is a whole number of pixels, and this one holds a fraction. " \
                "To fix this, write a whole number from 1 to #{largest}, or drop the fraction with `.to_i`."
        end

        fixed = DSL::Value.fixed_number(size)
        return if fixed.nil? || (1..largest).cover?(fixed)

        raise ArgumentError,
              "pixelate's size is how many pixels a block is each way, from 1 to #{largest}. " \
              "You gave #{fixed}. A size of 1 is the picture as drawn."
      end

      # WHICH THINGS ARE DRAWN IN BLOCKS IS SETTLED AS THE CARTRIDGE IS BUILT. The console
      # keeps that as a switch on each background and each sprite, and the switches are
      # set once: all that changes while the game runs is the size of a block. So a game
      # has one answer to "what is left as drawn", and two different ones is a friendly
      # error here rather than a second set of switches to keep in step every frame.
      def refuse_second_pixelate_place!(under)
        @pixelate_place = under unless defined?(@pixelate_place)
        return if @pixelate_place == under

        said = ->(place) { place ? "`under: :#{place}`" : "no `under:`" }
        raise ArgumentError,
              "This game already pixelates with #{said.call(@pixelate_place)}, and now with " \
              "#{said.call(under)}. A game pixelates from one place in the stack, because which " \
              "things are drawn in blocks is settled once, before it runs. To fix this, give " \
              "every `pixelate` the same `under:`."
      end

      # A GAME HAS ONE LIGHT. The console has one window shaped row by row, and a light is
      # that window, so a second `spotlight` would quietly take the first one's place.
      def refuse_second_spotlight!
        return unless @spotlight

        if @spotlight_unsaid
          raise ArgumentError,
                "This game declares `spotlight` after an `iris_out` (or a `spotlight` with nothing " \
                "after it) already gave it a light. A game has one light. To fix this, declare " \
                "`spotlight at: [x, y], radius: r` before the first `iris_out`."
        end

        raise ArgumentError,
              "This game declares `spotlight` twice. A game has one light, and moves it with the " \
              "handle the first `spotlight` gives back. To fix this, keep the handle " \
              "(`light = spotlight at: [x, y], radius: r`) and change `light.x`, `light.y`, " \
              "`light.radius` and `light.dark` where the second light was."
      end

      # A light is a window in the picture the console composes from tiles. A bitmap screen
      # is one picture the game paints, with nothing composed to cut a window in; the
      # turning-background screen has the window, but this framework does not switch it on
      # there yet, and the console would darken the whole screen.
      def refuse_spotlight_off_tiles!
        return if @screen_mode.nil? || @screen_mode == :tiled

        raise ArgumentError,
              "`spotlight` needs a `screen :tiled`. This game is on `screen :#{@screen_mode}`, where " \
              "a light would darken the whole screen and not only the part outside it. To fix this, " \
              "use `screen :tiled` for the screen with the light."
      end

      def refuse_spotlight_with_no_radius!
        raise ArgumentError,
              "`spotlight` needs `radius:`, how far the light reaches in pixels: " \
              "`spotlight at: [120, 80], radius: 40`. To get the game's light back, write `spotlight` " \
              "with nothing after it."
      end

      # Where a light STARTS is a number, applied once at power-on like a variable's; where
      # it goes after that is the handle's.
      def refuse_spotlight_start!(at, radius, dark)
        unless at.is_a?(Array) && at.length == 2 && at.all?(Integer)
          raise ArgumentError,
                "`spotlight at:` is where the light starts, as two whole numbers: `at: [120, 80]`. " \
                "You gave #{at.inspect}. To move it as the game runs, use the handle: `light.move_to x, y`."
        end
        unless radius.is_a?(Integer) && radius >= 0
          raise ArgumentError,
                "`spotlight radius:` is how far the light reaches, as a whole number of pixels, 0 or " \
                "more. You gave #{radius.inspect}. To change it as the game runs, use `light.radius`."
        end
        return if dark.is_a?(Integer) && (0..100).cover?(dark)

        raise ArgumentError,
              "`spotlight dark:` is how dark the picture is outside the light, as a whole number from " \
              "0 to 100. You gave #{dark.inspect}. To change it as the game runs, use `light.dark`."
      end

      # A fade's or a tint's amount for the tree, and how many bits of fraction it carries
      # (nil for a whole percentage). An amount with a fraction — a Float, or a value that
      # holds one — is a percentage all the same, kept finer, and a long fade walked by it
      # moves a step on every frame rather than every other (see IR::Fading).
      def effect_amount(verb, amount)
        bits = DSL::Fraction.bits_of(amount)
        written = amount.is_a?(Float)
        node = written ? Build.int(DSL::Fraction.scale(amount, bits)) : DSL::Value.node_for(amount)
        fixed = written ? amount : DSL::Value.fixed_number(amount)
        fixed = fixed.fdiv(1 << bits) if fixed && bits && !written
        if fixed && !(0..100).cover?(fixed)
          raise ArgumentError,
                "#{verb}'s amount is how far to go, from 0 to 100. You gave #{fixed}."
        end

        [node, bits]
      end

      # What `estimate: { usually: N }` said about how tall this shape normally is — a stretched
      # column or a rectangle, which take the hint for the same reason and refuse it for the
      # same one. Only a height the game works out can be told: one written in the program is
      # already known, and saying it twice invites the two to disagree.
      def usual_stretch_height(height, estimate, shape)
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
      def resolve_screen_colors(colors, tear_free)
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

        colors.map { |spec| Graphics::Color.resolve(spec) }
      end

      def validate_coords!(x, y)
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{SCREEN_WIDTH - 1}." unless (0...SCREEN_WIDTH).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{SCREEN_HEIGHT - 1}." unless (0...SCREEN_HEIGHT).cover?(y)
      end
    end
  end
end
