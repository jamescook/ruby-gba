# frozen_string_literal: true

module RubyGBA
  class Builder
    # THE CIRCLE A SPOTLIGHT LIGHTS, worked out a row at a time.
    #
    # What the picture is told is a span for each row of the screen: the columns from a left
    # edge up to (not including) a right edge are drawn as they are, and the rest of the row
    # is darkened. A circle is a span per row that is widest across the middle and narrows to
    # nothing at the top and bottom, so all of this is working out how wide the circle is on
    # a given row.
    #
    # UP TO A SIZE OF 150 IT IS THE MIDPOINT CIRCLE, looked up row by row from a table of every
    # such circle (see MIDPOINT_LARGEST), because that is the circle the console's games draw.
    # Past that it is a square root:
    #
    # A SQUARE ROOT is something nothing on the console does quickly, so it is looked up.
    # How far a row is from the middle, as a share of the radius, picks an entry of a table
    # of half widths for a circle 256 across, and the radius scales it. Taking the share
    # would be a divide on every row; it is a multiply instead, by a second table holding
    # what one pixel is as a share of each radius. Every row then costs two reads, two
    # multiplies and a few steps, and nothing about it depends on how big the light is.
    #
    # It is written in the game's own words — a Value, a table read, a clamp — so the
    # console and the interpreter work out the very same numbers: neither has a circle of
    # its own to disagree about.
    module Spotlights
      # The light's four numbers, and the row the spans are worked out for, named with the
      # framework's underscore prefix so a game's own variables can never collide with them.
      X = :__spotlight_x
      Y = :__spotlight_y
      RADIUS = :__spotlight_radius
      DARK = :__spotlight_dark
      ROW = :__spotlight_row

      # The row's half width, worked out once a row before either edge reads it.
      HALF = :__spotlight_half

      # How dark outside a light is when its declaration does not say: dark enough to read as
      # a light in the dark, light enough that the room is still there.
      DARK_UNSAID = 75

      WIDTHS = :__spotlight_widths
      SHARES = :__spotlight_shares

      # The biggest radius worked out. A light whose middle is in the far corner of the
      # screen reaches the other corner at 289, so this lights the whole screen from
      # anywhere on it with room to spare, and a power of two keeps the table reads cheap.
      LARGEST = 511

      # A share of the radius is counted in 256ths, and the multiply that makes one counts
      # in 32768ths so the table entries are whole numbers that fit in half a word.
      SHARE_STEPS = 256
      SHARE_SCALE = 32_768
      SHARE_SHIFT = 7 # SHARE_SCALE / SHARE_STEPS is 2 to this

      # How wide a circle 256 across is, from its middle out, at each 256th of the way from
      # its middle to its edge. The second half of the table is nought: a row that far from
      # the middle is outside the circle, and reading nought there is what keeps it dark
      # with no test on every row.
      HALF_WIDTHS = Array.new(SHARE_STEPS * 2) do |share|
        share < SHARE_STEPS ? (SHARE_STEPS * Math.sqrt(1 - ((share.to_f / SHARE_STEPS)**2))).round : 0
      end.freeze

      # What one pixel is as a share of each radius, in 32768ths. ROUNDED UP, and that is
      # load-bearing: a row exactly a radius from the middle has to come out at the circle's
      # edge or past it, and rounding down would leave it a little inside, lighting a short
      # sliver at the very top and bottom of a big light.
      SHARES_OF_RADIUS = Array.new(LARGEST + 1) do |radius|
        radius.zero? ? 0 : (SHARE_SCALE + radius - 1) / radius
      end.freeze

      module_function

      # A SMALLER CIRCLE IS THE ONE GAMES DRAW, row for row. The console's own games make their
      # window circles with the midpoint circle — whole-number steps round an eighth of the
      # circle, mirrored into the rest — and a game copying one has to land on its every pixel,
      # which the scaled table above does not: it comes out a pixel or a few narrower at each
      # edge. So up to the biggest circle such a game draws, the half widths are that circle's
      # own, worked out here for every size and kept in the cartridge, a row of them a size.
      # Past it the scaled table carries on, since a light that big is most of the screen.
      MIDPOINT_LARGEST = 150
      MIDPOINT = :__spotlight_midpoint

      # Entries a size: one for each row from the middle out to the largest size, and one more,
      # always nought, that a row beyond the circle reads.
      MIDPOINT_STRIDE = MIDPOINT_LARGEST + 2

      # The midpoint circle's half width on each row from its middle out, for a circle of
      # +size+: rows 0 to size - 1 lit, the rest nought. Written the way the console's games
      # write it (The Minish Cap: src/common.c, sub_0801E24C) — +turn+ says whether the next
      # step round the circle goes straight across or across and in.
      def midpoint_half_widths(size)
        widths = Array.new(size + 1, 0)
        across = 0
        down = size
        turn = 3 - (2 * size)
        while across <= down
          widths[across] = down
          widths[down] = across
          if turn.negative?
            turn += 6 + (across * 4)
          else
            turn += 10 + ((across - down) * 4)
            down -= 1
          end
          across += 1
        end
        Array.new(MIDPOINT_STRIDE) { |row| row < size ? widths[row] : 0 }
      end

      MIDPOINT_HALF_WIDTHS = (0..MIDPOINT_LARGEST).flat_map { |size| midpoint_half_widths(size) }.freeze

      # The statement that darkens the picture outside the circle +light+ says. Its edges read
      # the row's half width, which #work_out_half_width puts in HALF first.
      def shade_node(builder, light)
        half = builder.var(HALF, 0)
        screen = builder.console.screen_width
        left = (light.x - half).clamp(0, screen)
        right = (light.x + half).clamp(0, screen)

        Build.shade_outside(row: ROW, left: DSL::Value.node_for(left), right: DSL::Value.node_for(right),
                            amount: DSL::Value.node_for(light.dark))
      end

      # The three tables the circle is read from — the scaled half widths, one pixel as a share
      # of each radius, and the midpoint circles — declared once, with the light.
      def declare_tables(builder)
        [builder.table(WIDTHS, HALF_WIDTHS, width: :half),
         builder.table(SHARES, SHARES_OF_RADIUS, width: :half),
         builder.table(MIDPOINT, MIDPOINT_HALF_WIDTHS, width: :byte)]
      end

      # The statements that put the row's half width in HALF, recorded where +builder+ is
      # recording — the light's own statement, which runs them once a row. ONE of the two ways
      # runs on a row, picked by the light's size: working out both and choosing between them
      # would cost a row both, and the light is worked out for every row of every frame.
      #
      # +row+ is the row worked out for — the light's own row unless a shape asks for another
      # (see DSL::Spotlight#circle) — and +into+ the variable the half width is put in, which is
      # handed back.
      def work_out_half_width(builder, light, tables, row: builder.var(ROW, 0), into: HALF)
        widths, shares, midpoint = tables
        half = builder.var(into, 0)

        radius = light.radius.clamp(0, LARGEST)
        apart = (row - light.y).abs.clamp(0, LARGEST + 1)
        (radius > MIDPOINT_LARGEST).then do
          share = ((apart * shares[radius]) >> SHARE_SHIFT).clamp(0, LARGEST)
          half.set! (radius * widths[share]) >> 8
        end.else do
          half.set! midpoint[(radius * MIDPOINT_STRIDE) + apart.clamp(0, MIDPOINT_STRIDE - 1)]
        end
        half
      end
    end
  end
end
