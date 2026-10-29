# frozen_string_literal: true

module VBlank
  class Builder
    # The bitmap drawing verbs: pick a screen mode, then put color on the screen —
    # single pixels, filled rectangles (fixed or run-time positioned), a whole-screen
    # clear. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # The screen's size is the console's the game is built for (Builder#console), never one
    # console's numbers written here.
    module Drawing
      # The screens {#screen} knows by name: a pixel canvas, tile and sprite layers (most
      # games), and one background that turns and resizes with no scrolling ones. How each is
      # set up on a console is its lowering's business. The tear-proof double-buffered screen
      # isn't a separate name here: it's `screen :bitmap, tear_free: true`.
      SCREEN_NAMES = %i[bitmap tiled rotozoom].freeze

      # HOW BIG THE SCREEN IS, in pixels: 240 across and 160 down on a Game Boy Advance, 160 and
      # 144 on a Game Boy Color. A game written for both lays itself out from these rather than
      # from numbers for one screen, so the same block builds for either (see `consoles:` on
      # `VBlank.game`):
      #
      #   paddle_x = screen_width - 12
      #   draw_text "PONG", :center, screen_height / 4, :white
      def screen_width = console.screen_width

      # See #screen_width.
      def screen_height = console.screen_height

      # Choose what kind of screen you're drawing on.
      #
      # @param mode [Symbol, Integer] a friendly name or raw REG_DISPCNT value
      #
      # @example Friendly
      #   screen :bitmap          # a pixel canvas
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
      # @example Raw (full control, the Advance's display register written as it is)
      #   hw = VBlank::Console::Hardware
      #   screen hw::MODE_3 | hw::BG2_ENABLE | hw::OBJ_ENABLE
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
      #
      # Pass +late:+ to say what the tear-free screen does with a page the game finished too
      # late for the break between pictures it was meant for. By default (+:wait+) it waits for
      # the next break, so it never tears — but a frame a little late then costs a whole frame,
      # and a game at sixty drops to thirty for it. +:show_now+ shows such a page as soon as
      # it is done, which can tear on those frames. A row number (0 to 159) shows it at once
      # only while the screen is still drawing above that row, where a tear is least seen, and
      # waits otherwise. A late page finished during the break itself is shown at once by
      # either, since nothing is being drawn then. Said per `screen`, so a scene can allow it while the
      # game plays and forbid it on a menu. `rom.profile` counts the pages it showed at once.
      #
      # +pace:+ says what LATE means: the pictures a second the game aims for — 60 (the
      # default), 30, 20 or 15. A page is late when it misses the break that rate aims at. A
      # game that runs at thirty and says `pace: 30` shows at once only the pages that ran
      # over thirty, and the ones on time at thirty wait as they always did.
      #
      # @example A late page shown at once, if the tear is in the top quarter
      #   screen :bitmap, tear_free: true, late: 40
      # @example A game at thirty that does not drop to twenty on a heavy frame
      #   screen :bitmap, tear_free: true, late: :show_now, pace: 30
      def screen(mode, tear_free: false, colors: nil, late: :wait, pace: 60, backdrop: nil)
        case mode
        when Symbol
          unless SCREEN_NAMES.include?(mode)
            raise ArgumentError, "unknown screen mode: #{mode}. Known: #{SCREEN_NAMES.join(', ')}"
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
        late_rows = resolve_late_pages(late, tear_free)
        record(Build.screen(mode, buffered: tear_free, colors: resolve_screen_colors(colors, tear_free),
                                  late: late_rows, late_pace: resolve_late_pace(pace, late_rows),
                                  backdrop: resolve_backdrop(backdrop, mode)))
      end

      # THE COLOUR A SCREEN SHOWS WHEREVER NOTHING IS DRAWN, as the IR keeps it: nil for a screen
      # that says none, which shows the game's (black, the colour every screen has shown there
      # before, unless the game's own `screen` says another). A painted screen draws every pixel, so
      # it has nowhere to show one.
      private def resolve_backdrop(backdrop, mode)
        return nil if backdrop.nil?
        if mode == :bitmap
          raise ArgumentError, "`screen :bitmap` says backdrop:. A bitmap screen draws every pixel, so no backdrop " \
                               "shows. To fill the screen with a colour, use clear_screen."
        end

        Graphics::Color.resolve(backdrop) & 0x7FFF
      end

      # The breaks a pass may take and be on time, as the IR keeps them: nil for one.
      private def resolve_late_pace(pace, late_rows)
        breaks = IR::LatePages::PACES[pace]
        unless breaks
          raise ArgumentError, "pace: #{pace.inspect} is not a rate the screen can keep. Use 60, 30, 20 or 15 " \
                               "pictures a second."
        end
        if late_rows.nil? && breaks != 1
          raise ArgumentError, "pace: works only with late:. A screen that waits for every page has no late " \
                               "page to measure. To use pace:, add late: :show_now or a row."
        end
        breaks == 1 ? nil : breaks
      end

      # The rows a late page may still be shown at once above, as the IR keeps them: nil to
      # wait, IR::LatePages::ANY_ROW for :show_now, else the row the game named.
      private def resolve_late_pages(late, tear_free)
        return nil if late == :wait
        unless tear_free
          raise ArgumentError, "late: works only with `screen :bitmap, tear_free: true`. Only that screen keeps a " \
                               "finished page to show. To use late:, add tear_free: true."
        end
        return IR::LatePages::ANY_ROW if late == :show_now
        return late if late.is_a?(Integer) && (0...console.screen_height).cover?(late)

        raise ArgumentError, "late: #{late.inspect} is not a setting. Use :wait (the default), :show_now, or a " \
                             "row from 0 to #{console.screen_height - 1}."
      end

      # HOW MANY PICTURES THIS SCREEN KEEPS. A tear-free screen keeps two and shows
      # them in turn, so a change drawn once reaches only one of them; a plain screen
      # keeps one, so a change drawn once is done. This is the number of times a
      # picture that is drawn and then left alone has to be painted (Packs::KeepShowing).
      # A Game Boy Color keeps one page even then (Console::Description's painted_pages),
      # and the second paint there only draws the same picture again.
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
        left, right = [x, x + w].map { |edge| edge.clamp(0, console.screen_width) }
        top, bottom = [y, y + h].map { |edge| edge.clamp(0, console.screen_height) }
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
        at ||= console.middle
        refuse_spotlight_with_no_radius! if said && radius.nil?
        radius ||= Spotlights::LARGEST
        dark ||= said ? Spotlights::DARK_UNSAID : 0
        refuse_spotlight_start!(at, radius, dark)

        light = DSL::Spotlight.new(x: var(Spotlights::X, at[0]), y: var(Spotlights::Y, at[1]),
                                   radius: var(Spotlights::RADIUS, radius), dark: var(Spotlights::DARK, dark),
                                   builder: self)
        @spotlight_tables = Spotlights.declare_tables(self)
        shade = Spotlights.shade_node(self, light)
        push_container(shade) { Spotlights.work_out_half_width(self, light, @spotlight_tables) }
        record(shade)
        @spotlight_shade = shade
        @spotlight_unsaid = !said
        @spotlight = light
      end


      # THE HOOK BEHIND Spotlight#shape: the block's statements become the ones the light runs
      # once a row, and what it gives back the row's two edges, held to the screen. The circle
      # the light had is put aside.
      def record_light_shape(light, &block)
        refuse_light_shape_with_no_block!(block)
        refuse_second_light_shape!
        shade = @spotlight_shade
        before = @variables.to_a
        shade.children.clear
        edges = nil
        begin
          @shaping_light = true
          push_container(shade) { edges = yield(DSL::Value.handed_to_block(self, Build.var_ref(Spotlights::ROW))) }
        ensure
          @shaping_light = false
        end
        left, right = light_edges(light, edges)
        shade.left = DSL::Value.node_for(left)
        shade.right = DSL::Value.node_for(right)
        own = @variables.to_a - before
        refuse_light_shape_with_side_effects!(shade, own)
        start_own_variables_every_row(shade, own)
        @light_shape_own = own
        @light_shaped = true
      end

      # THE HOOK BEHIND Spotlight#circle: the statements that work out the light's circle on
      # +row+, into a variable of the shape's own, which is handed back.
      def light_circle(light, row)
        unless @shaping_light
          raise ArgumentError, "`light.circle` works out a row of the light's circle for a shape. " \
                               "To use it, call it inside `light.shape { |row| ... }`."
        end

        @light_circles = (@light_circles || 0) + 1
        Spotlights.work_out_half_width(self, light, @spotlight_tables, row: row, into: :"__spotlight_circle_#{@light_circles}")
      end

      # THE HOOK BEHIND Spotlight#show_now: the light worked out again here, for the picture
      # being drawn.
      def show_light_now
        record(Build.show_light_now)
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
      # @param estimate [Object] does nothing but earn a warning (see Builder#record_estimate_line)
      def draw_column_at(name, slice:, x:, top:, height:, width: 1, estimate: nil)
        record_estimate_line(estimate)
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
                                    DSL::Value.node_for(top), DSL::Value.node_for(height), width: width))
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
      # @param estimate [Object] does nothing but earn a warning (see Builder#record_estimate_line)
      def draw_rect_at(x_pos, y_pos, w, h, c, estimate: nil)
        record_estimate_line(estimate)
        record(Build.draw_rect_at(DSL::Value.node_for(x_pos), DSL::Value.node_for(y_pos),
                                  DSL::Value.node_for(w), DSL::Value.node_for(h), c))
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

      # SWITCH THE LIGHT OFF IN THE SCENES IT IS OFF IN: those that see through a layer, or
      # fade under one (see IR::LightScenes). Each scene says, as it starts its pass, whether
      # the light is on, and the light's darkness is that much of what the game says — so
      # every backend works out the same picture from the program alone. A game whose light
      # is on in every scene gets none of this.
      def finalize_light_switch
        return unless @spotlight

        refuse_light_shape_variable_shared!
        dark = IR::LightScenes.dark(program)
        return if dark.empty?

        var(IR::LightScenes::ON, 1)
        scenes = IR::LightScenes.scenes(program)
        program.walk.select { |node| node.kind == :func && scenes.include?(node.name) }.each do |scene|
          switch = Build.set(IR::LightScenes::ON, Build.int(dark.key?(scene.name) ? 0 : 1))
          scene.children.unshift(switch)
          switch.parent = scene
        end
        light = IR::LightScenes.light_of(program)
        light.amount = Build.binop(:*, light.amount, Build.var_ref(IR::LightScenes::ON))
      end

      def refuse_light_shape_with_no_block!(block)
        return if block

        raise ArgumentError, "`light.shape` needs a block that gives back each row of the light: " \
                             "`light.shape { |row| 40 - (row - light.y).abs }`."
      end

      def refuse_second_light_shape!
        return unless @light_shaped

        raise ArgumentError, "This game gives the light a shape twice. A light has one shape. " \
                             "To fix this, keep one `light.shape`, and work the difference out inside it."
      end

      # A ROW'S TWO EDGES, held to the screen, from what a shape gave back: a half width either
      # side of the light's middle (never less than nothing), or [left, right] as they are.
      def light_edges(light, edges)
        screen = console.screen_width
        number = ->(edge) { edge.is_a?(Integer) || edge.is_a?(DSL::Value) }
        if edges.is_a?(Array) && edges.length == 2 && edges.all?(&number)
          left, right = edges
        elsif number.call(edges)
          half = edges.clamp(0, screen)
          left = light.x - half
          right = light.x + half
        else
          refuse_light_edges!(edges)
        end
        [left.clamp(0, screen), right.clamp(0, screen)]
      end

      def refuse_light_edges!(edges)
        raise ArgumentError, "`light.shape` needs a block that gives back a half width (a number) " \
                             "or a row's two edges, [left, right]. This one gave back #{edges.inspect}."
      end

      # WHAT A SHAPE MAY DO, and why it is a short list: the rows are worked out in the gap before
      # a frame, and the console skips them on a frame where nothing they read has changed. So a
      # row has to come out of the row and the game's numbers alone. A shape works numbers out —
      # from variables, tables and arithmetic — keeps them in variables of its own, branches and
      # loops; anything else would read something the console does not watch, or change the game
      # at different times on different machines.
      LIGHT_SHAPE_STATEMENTS = %i[set add sub copy negate abs negate_abs clamp if else repeat table].freeze
      LIGHT_SHAPE_VALUES = %i[int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right
                              table_get data_byte].freeze

      # What the commonest things a shape cannot do are, said as the game says them.
      LIGHT_SHAPE_CANNOT = { list_get: "read a list", list_len: "read a list", held: "read the buttons",
                             pressed: "read the buttons", chance: "pick a number at random",
                             call: "call a routine", call_one_of: "call a routine" }.freeze

      # Refused where the shape is written, so the error points at it: anything off the list above,
      # a random number, which moves the stream every other part of the game draws from, and a
      # change to any variable the shape did not declare.
      def refuse_light_shape_with_side_effects!(shade, own)
        [*shade.children, shade.left, shade.right].flat_map { |part| part.walk.to_a }.each do |node|
          written = IR::LightScenes.written_var(node)
          if written == Randomness::RNG_STATE
            raise ArgumentError, "The light's shape picks a number at random. The random numbers are one stream " \
                                 "that the whole game shares, and a shape cannot move it. To fix this, pick " \
                                 "the number outside the shape into a variable, and read that variable in the shape."
          end
          unless (node.value? ? LIGHT_SHAPE_VALUES : LIGHT_SHAPE_STATEMENTS).include?(node.kind)
            did = LIGHT_SHAPE_CANNOT.fetch(node.kind) { "use `#{Messages::PlainWords.verb(node.kind)}`" }
            raise ArgumentError, "The light's shape tries to #{did}. A shape can only work numbers out from " \
                                 "the game's numbers and tables, keep them in variables it declares, branch and " \
                                 "repeat. To fix this, do the work outside the shape, keep the number in a " \
                                 "variable, and read that variable in the shape."
          end
          next if written.nil? || own.include?(written)

          raise ArgumentError,
                "The light's shape changes the variable :#{written}. A shape can change only the variables it " \
                "declares itself. To fix this, declare a variable inside the shape's block, or change " \
                ":#{written} outside the shape."
        end
      end

      # A SHAPE'S OWN VARIABLES START EVERY ROW AS THEY WERE DECLARED. Nothing then carries from
      # one row to the next, or from one frame to the next, so a row is the row and the game's
      # numbers and nothing else — which is what lets the console keep rows it worked out before.
      def start_own_variables_every_row(shade, own)
        own.reverse_each do |name|
          start = @boot_inits.find { |node| node.kind == :set && node.var == name }&.value
          reset = Build.set(name, start ? start.copy : Build.int(0))
          shade.children.unshift(reset)
          reset.parent = shade
        end
      end

      # The variables a shape declared are its alone: one the rest of the game also reads or
      # changes would be put back every row, so the game would see it change for no reason, and
      # on the console only on the frames whose rows are worked out again.
      def refuse_light_shape_variable_shared!
        return unless @light_shape_own&.any?

        in_shade = @spotlight_shade.walk.to_set
        program.walk.reject { |node| in_shade.include?(node) }.each do |node|
          named = node.kind == :copy ? [node.src, node.dest] : [IR::LightScenes.written_var(node), (node.name if node.kind == :var_ref)]
          shared = (named & @light_shape_own).first
          next unless shared

          raise ArgumentError,
                "The light's shape declares the variable :#{shared}, and the rest of the game uses it too. " \
                "A shape puts its own variables back on every row. To fix this, give the shape's variable " \
                "a name of its own."
        end
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
        width, height = console.screen_size
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{width - 1}." unless (0...width).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{height - 1}." unless (0...height).cover?(y)
      end
    end
  end
end
