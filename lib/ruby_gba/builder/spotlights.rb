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
    # THAT IS A SQUARE ROOT, which nothing on the console does quickly, so it is looked up.
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

      # The statement that darkens the picture outside the circle +light+ says.
      def shade_node(builder, light)
        widths = builder.table(WIDTHS, HALF_WIDTHS, width: :half)
        shares = builder.table(SHARES, SHARES_OF_RADIUS, width: :half)
        row = builder.var(ROW, 0)

        radius = light.radius.clamp(0, LARGEST)
        apart = (row - light.y).abs.clamp(0, LARGEST + 1)
        share = ((apart * shares[radius]) >> SHARE_SHIFT).clamp(0, LARGEST)
        half = (radius * widths[share]) >> 8
        screen = Console::Hardware::SCREEN_WIDTH
        left = (light.x - half).clamp(0, screen)
        right = (light.x + half).clamp(0, screen)

        Build.shade_outside(row: ROW, left: DSL::Value.node_for(left), right: DSL::Value.node_for(right),
                            amount: DSL::Value.node_for(light.dark))
      end
    end
  end
end
