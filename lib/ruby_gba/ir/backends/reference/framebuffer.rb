# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # A simulated screen — the reference backend's stand-in for the display a real
        # console would draw to. It's just a grid of colors: every cell holds one
        # color directly, and drawing means writing colors into cells. Tests read
        # cells back to assert what a program *would* put on screen, with no
        # emulator and no ROM.
        #
        # The default size, 240x160, is the console's bitmap-mode screen. Writes
        # that fall outside the grid are silently dropped rather than raising or
        # scribbling onto memory — the same edge-safety the DSL promises, so a
        # stray pixel at (999, 999) can never corrupt anything or crash a test.
        class Framebuffer
          # Sized from the shared display contract, not a fresh copy of 240x160.
          WIDTH = Screen::WIDTH
          HEIGHT = Screen::HEIGHT

          attr_reader :width, :height, :camera_x, :camera_y, :fade_toward, :fade_amount,
                      :tint_color, :tint_amount

          # A color channel runs 0..31, and a full fade is 16 steps. Both come from the
          # display contract every backend blends against, so the two agree step for step.
          CHANNEL_MAX = 31
          FADE_STEPS = 16

          # @param fill [Integer] the color every cell starts as (0 reads as black)
          def initialize(width: WIDTH, height: HEIGHT, fill: 0)
            @width = width
            @height = height
            @fill = fill
            @pixels = Array.new(width * height, fill)
            @camera_x = 0
            @camera_y = 0
            @fade_toward = :black
            @fade_amount = 0
            @tint_color = nil
            @tint_amount = 0
            @paint_toward = nil
            @paint_steps = 0
            @through_steps = 0
            @blending = false
          end

          # Move the visible window over the stored picture: after this, screen (0, 0)
          # shows what was drawn at (x, y). Nothing stored moves — a camera changes what
          # you LOOK at, not what is there — which is why a shake costs no redrawing.
          def camera_to(x, y)
            @camera_x = x
            @camera_y = y
          end

          # Blend everything shown toward +toward+ (:black or :white) by +amount+, 0 to
          # 100. Like the camera, this changes what you SEE and not what is stored, so a
          # fade costs no redrawing and the picture is still all there underneath.
          def fade_to(toward, amount)
            @fade_toward = toward
            @fade_amount = amount
            @tint_color = nil # a display holds one of these at a time — see #tint_to
          end

          # Blend everything shown toward +color+ by +amount+, 0 to 100. Same idea as
          # fade_to, for the colors a fade cannot reach: moving a picture toward black or
          # white is a change of BRIGHTNESS, which a display can do to a finished picture,
          # while moving it toward red means mixing red IN.
          #
          # A display holds ONE such effect at a time, so setting a tint puts away
          # whatever fade was in force and the other way round. That is the display's own
          # rule rather than a simplification here, and modelling it is what stops a
          # program looking right on one backend and wrong on another.
          def tint_to(color, amount)
            @tint_color = color
            @tint_amount = amount
            @fade_amount = 0
          end

          # Blend everything painted FROM HERE ON toward +toward+ by +amount+ (0 to 100),
          # or paint colors as they are when +toward+ is nil.
          #
          # This is the other half of fade_to, and the two are not interchangeable. A fade
          # over the whole screen blends the finished picture as it is read, which changes
          # nothing that was drawn. A fade placed in the stack has to reach what is behind
          # it and leave what is in front of it alone — so the compositor turns this on
          # while it paints the things behind the line and off before the things in front,
          # and the finished picture already carries the blend.
          def paint_faded(toward, amount)
            @paint_toward = toward
            @paint_steps = toward.nil? ? 0 : steps_of(amount)
            @blending = blending?
          end

          # Blend everything painted FROM HERE ON with what is already in the cell, by
          # +amount+ (0 to 100) — a see-through layer.
          #
          # This is the one blend that needs the DESTINATION, which is why it cannot be
          # #paint_faded with a different color: a fade mixes toward a color that is the
          # same everywhere, and a see-through layer mixes toward whatever happens to be
          # underneath at that pixel. And it works BECAUSE the picture is painted back to
          # front — "blend with whatever is already there" and the display's own "blend
          # with the layer directly beneath" are then the same rule, so nothing about the
          # stack has to be modelled a second time.
          def paint_through(amount)
            @through_steps = steps_of(amount)
            @blending = blending?
          end

          # The color shown at screen (x, y) — the stored cell the window currently puts
          # there, blended by whatever fade is on. An off-screen coordinate reads as nil
          # ("there is no such pixel"). A window pushed off the drawn picture shows the
          # backdrop along that edge, the same as a display with nothing left to fetch
          # there.
          def pixel(x, y)
            return nil unless in_bounds?(x, y)

            faded(stored_pixel(x + @camera_x, y + @camera_y) || @fill)
          end

          # The color stored at (x, y), ignoring where the window sits. This is what the
          # drawing engine reads — saving the pixels under a sprite has to see what is
          # really in the picture, not what happens to be on screen right now.
          def stored_pixel(x, y)
            return nil unless in_bounds?(x, y)

            @pixels[(y * @width) + x]
          end

          # Paint one cell. Off-screen coordinates are dropped (see the class note
          # on edge-safety), so this never raises for a bad (x, y).
          def set_pixel(x, y, color)
            return unless in_bounds?(x, y)

            at = (y * @width) + x
            @pixels[at] = laid(at, color)
          end

          # Paint a horizontal run of cells: +count+ of them starting at (x, y), read
          # from +colors+ beginning at +from+. A nil in +colors+ leaves that cell as it
          # is, so a see-through pixel keeps whatever is behind it.
          #
          # The run has to be on the screen. This is the compositor's path — it walks
          # the screen a tile at a time and knows its own coordinates are inside it —
          # so it skips the per-cell edge check set_pixel does. That check is most of
          # the cost when a whole scrolling scene is repainted every frame.
          def paint_row(x, y, colors, from:, count:)
            base = (y * @width) + x
            i = 0
            while i < count
              color = colors[from + i]
              # The blend is asked for inline rather than through #laid, which would be
              # a method call per pixel on the path that repaints the whole scene.
              @pixels[base + i] = @blending ? laid(base + i, color) : color if color
              i += 1
            end
          end

          # Paint a w-by-h rectangle whose top-left is (x, y). Any part hanging off
          # the screen is clipped, because each cell goes through set_pixel.
          def fill_rect(x, y, width, height, color)
            y.upto(y + height - 1) do |py|
              x.upto(x + width - 1) do |px|
                set_pixel(px, py, color)
              end
            end
          end

          # Paint the entire screen one color.
          def clear(color)
            @pixels.fill(painted(color))
          end

          # A flat, row-major copy of every cell as it is STORED — for counting how many
          # cells hold a given color, or asserting what was drawn.
          def to_a
            @pixels.dup
          end

          # The same screen as it is SHOWN: the window's offset applied, and whatever fade
          # or tint is on blended in. The companion to #to_a, and the two are not
          # interchangeable.
          #
          # Where they differ is exactly where an effect is on, and that difference is the
          # whole point of an effect: a fade changes NOTHING that was drawn, which is what
          # makes it cost the same however much is on screen and come back untouched. So
          # anything comparing this screen with a real display has to read this one — the
          # stored cells are a picture nobody is looking at.
          def shown
            return to_a if plain?

            Array.new(@width * @height) { |i| pixel(i % @width, i / @width) }
          end

          # Nothing between what is stored and what is shown: the window at the origin and
          # no effect in force. The common case, and worth not walking the screen for.
          def plain?
            @camera_x.zero? && @camera_y.zero? && @tint_color.nil? && fade_steps.zero?
          end

          private

          # One color with the current fade applied.
          #
          # A color is three 5-bit channels packed into a halfword, and the fade moves
          # each channel a fraction of the way to its limit. So a mid-fade picture keeps
          # its shape and loses its color, rather than every pixel jumping at once.
          #
          # THE TWO DIRECTIONS ARE NOT MIRROR IMAGES, and where the truncation falls is
          # the whole of the difference. Toward white, a channel ADDS a share of the
          # headroom it has left, and that share is truncated on its own. Toward black it
          # KEEPS a share of what it has — which is not the same as taking a truncated
          # share away, because the two round in opposite directions. A channel at the top
          # blended a quarter of the way to black keeps 23, where taking a quarter away
          # would leave 24.
          #
          # The fractions are in sixteenths and the arithmetic is whole-number, which is
          # what the display does. Matching it exactly is what lets a test name one
          # expected color and assert it on both backends.
          def faded(color)
            return mixed(color, @tint_color, steps_of(@tint_amount)) if @tint_color

            blend(color, @fade_toward, fade_steps)
          end

          # One color mixed toward another, the way a display's blend unit does it: each
          # channel takes its share of the picture and its share of the other color, the
          # two are ADDED, and only then is the sixteenth dropped.
          #
          # WHERE THE TRUNCATION FALLS IS THE WHOLE OF IT, and it is not the same as the
          # brightness blend below. Truncating each share on its own and adding them can
          # land a whole step lower — white mixed half way toward red keeps 30 of its red
          # that way and 31 this way — so a picture where both sides have something in a
          # channel comes out different. Measured on hardware, which is where this
          # rounding is decided; matching it exactly is what lets a test name one
          # expected color and assert it on both backends.
          #
          # The two shares are in sixteenths and always add to sixteen, so no channel can
          # come out above its limit and there is nothing to clamp.
          def mixed(color, toward, steps)
            return color if steps.zero?

            keep = FADE_STEPS - steps
            packed = 0
            3.times do |channel|
              shift = channel * 5
              have = (color >> shift) & CHANNEL_MAX
              want = (toward >> shift) & CHANNEL_MAX
              packed |= (((have * keep) + (want * steps)) / FADE_STEPS) << shift
            end
            packed
          end

          # One color on its way into the cell at +at+: the blend a placed fade asks for,
          # then the blend a see-through layer asks for against what is already there.
          # Untouched when neither is on, which is the usual case.
          def laid(at, color)
            color = painted(color)
            return color if @through_steps.zero?

            mixed(color, @pixels[at], @through_steps)
          end

          # One color with the blend a placed fade asks for, or the color untouched when
          # no fade is placed. The same arithmetic as #faded, so a picture blended while
          # it is painted and one blended while it is read cannot come out different.
          def painted(color)
            @paint_toward ? blend(color, @paint_toward, @paint_steps) : color
          end

          # Is anything between the color asked for and the cell it lands in? Kept as one
          # flag rather than two questions, because it is asked once per pixel on the path
          # that repaints a whole scrolling scene.
          def blending?
            !@paint_toward.nil? || @through_steps.positive?
          end

          def blend(color, toward, steps)
            return color if steps.zero?

            channels = [color & 0x1F, (color >> 5) & 0x1F, (color >> 10) & 0x1F]
            blended = channels.map do |c|
              if toward == :white
                c + (((CHANNEL_MAX - c) * steps) / FADE_STEPS)
              else
                (c * (FADE_STEPS - steps)) / FADE_STEPS
              end
            end
            blended[0] | (blended[1] << 5) | (blended[2] << 10)
          end

          # How far the fade goes, in sixteenths. Out-of-range amounts settle at the
          # ends rather than wrapping or raising, the same as the hardware.
          def fade_steps
            steps_of(@fade_amount)
          end

          def steps_of(amount)
            ((amount * FADE_STEPS) / 100).clamp(0, FADE_STEPS)
          end

          def in_bounds?(x, y)
            x >= 0 && x < @width && y >= 0 && y < @height
          end
        end
      end
    end
  end
end
