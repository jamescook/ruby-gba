# frozen_string_literal: true

module Wolf3D
  # The pictures of the things that STAND in a level — the guards — laid side by side in one
  # picture, exactly as the walls are, so that which one to draw is arithmetic on a column
  # number and never a choice made as the game runs.
  #
  # A SECOND PICTURE RATHER THAN MORE OF THE WALLS' ONE, and speed is the whole reason. These
  # pictures are mostly nothing: a guard is a man standing in a square, and everywhere he is
  # not has to let the room behind him show. A picture that CAN be see-through is asked about
  # it at every pixel it draws, and the walls are the hottest thing this game does — three
  # hundred and something columns of them a frame, every pixel of every one. Keeping them in a
  # picture that cannot be see-through means they never ask.
  class ThingAtlas
    SIDE = Vswap::Sprite::SIDE

    attr_reader :sprites

    def initialize(vswap, palette, sprites)
      @vswap = vswap
      @palette = palette
      @sprites = sprites
    end

    def empty? = @sprites.empty?

    # Where a picture sits in the row, counting pictures...
    def position_of(sprite) = @sprites.index(sprite)

    # ...and the same as a COLUMN number, which is what a stretched column is asked for.
    def slice_of(sprite) = position_of(sprite) * SIDE

    def width = [@sprites.length, 1].max * SIDE
    def height = SIDE

    # Column-major in the file, and a picture here is row-major, so this is the one place the
    # two orders meet — the same crossing the walls make, over a sprite's see-through pixels.
    def pixels
      return Array.new(SIDE * SIDE, :transparent) if empty?

      rows = Array.new(SIDE) { [] }
      @sprites.each do |index|
        sprite = @vswap.sprite(index)
        SIDE.times do |y|
          SIDE.times do |x|
            value = sprite[x, y]
            rows[y] << (value.nil? ? :transparent : @palette[value])
          end
        end
      end
      rows.flatten
    end

    # WHICH COLUMNS OF A PICTURE HOLD ANYTHING. A guard fills about a third of the width of
    # his square and the rest is room showing through, so the strips either side of him are
    # work with nothing to show for it — and worse than nothing, because a strip that draws
    # no pixel still says it covered that part of the screen, which would rub out anything
    # standing behind it.
    #
    # Both numbers count from the LEFT EDGE of the picture, which is what the drawing walks.
    def first_column(sprite) = @vswap.sprite(sprite).first_column
    def last_column(sprite) = @vswap.sprite(sprite).last_column
  end
end
