# frozen_string_literal: true

module Wolf3D
  # The pictures of the gun in your hands, laid side by side in one picture the way the walls
  # and the standing things are — so which frame shows is arithmetic on a column number and
  # never a choice made as the game runs.
  #
  # WHERE THEY ARE. Not in VGAGRAPH, which is where the status bar's little weapon icons live:
  # the gun you hold is in VSWAP with the guards and the lamps, as the LAST twenty sprites of
  # the file — five frames each for the knife, the pistol, the machine gun and the chain gun,
  # in that order. Read off a real copy rather than counted out of the source: on the six-
  # episode release those are sprites 416 to 435 of 436, and every one of them sits hard
  # against the bottom of its square while the four sprites before them fill their squares
  # top to bottom.
  #
  # AND THAT LAST FACT IS WORTH A PICTURE OF ITS OWN. A gun hangs at the bottom of the screen,
  # so the top of its square is empty in every frame — over a third of it, measured. Cutting
  # those rows out here means they are neither shipped in the cartridge nor walked down when
  # the gun is drawn: the picture is the band that holds art, and the drawing puts that band
  # where the square's rows would have fallen.
  class WeaponAtlas
    SIDE = Vswap::Sprite::SIDE

    # The four, in the order the file holds them, which is also the order you walk through
    # them: the knife is weapon one and the chain gun the best you can hold.
    WEAPONS = %i[knife pistol machine_gun chain_gun].freeze

    # ...and how many pictures each has: at rest, then the four it attacks with.
    FRAMES = 5
    COUNT = WEAPONS.length * FRAMES

    # Does this copy of the game hold them? Every release does — it is the same twenty sprites
    # in the shareware and the registered files — but a fixture written with fewer sprites than
    # this has no gun to draw, and says so rather than reading somebody else's pictures.
    def self.in?(vswap) = !vswap.nil? && vswap.sprite_count >= COUNT

    # Where the knife's first picture sits in VSWAP's own numbering.
    def self.first_sprite(vswap) = vswap.sprite_count - COUNT

    def initialize(vswap, palette)
      @palette = palette
      first = self.class.first_sprite(vswap)
      @frames = (0...COUNT).map { |n| vswap.sprite(first + n) }
    end

    # WHICH ROWS OF THE SQUARE HOLD ANYTHING, over all twenty frames at once. One band for all
    # of them and not one each, because every frame is drawn in the same place on the screen —
    # a band that moved with the picture would make the gun jump about as it fired.
    def top_row = @top_row ||= @frames.map(&:first_row).min
    def bottom_row = @bottom_row ||= @frames.map(&:last_row).max

    def width = COUNT * SIDE
    def height = bottom_row - top_row + 1

    # Where a frame's columns start in the row of them. Which frame is `weapon * FRAMES + pose`.
    def slice_of(frame) = frame * SIDE

    # WHICH COLUMNS OF EACH FRAME HOLD ANYTHING, which is what stops the drawing walking down
    # the screen for nothing. The knife at rest is ten columns of its sixty-four; a chain gun
    # firing is over fifty. Both numbers come out of the file's own header.
    def first_columns = @frames.map(&:first_column)
    def last_columns = @frames.map(&:last_column)

    # HOW MANY COLUMNS THE DRAWING WALKS ON A NORMAL FRAME, and the most it can ever walk. For
    # the estimate only — nothing about how the game runs reads either, and the loop that walks
    # them is counted by a number the game works out, which is charged nothing at all unsaid.
    #
    # A NORMAL FRAME IS A GUN AT REST, which is why this is not the average over all twenty: you
    # carry a weapon for whole minutes and fire it for a fifth of a second, so the four at-rest
    # frames are what the screen shows nearly all the time. They are also the narrowest of each
    # weapon's five — a chain gun firing is five times the width of a knife held still — so the
    # two numbers here are far apart on purpose.
    def usual_columns
      at_rest = (0...WEAPONS.length).map { |n| columns_of(n * FRAMES) }
      (at_rest.sum.to_f / at_rest.length).ceil
    end

    def most_columns = (0...COUNT).map { |n| columns_of(n) }.max

    def columns_of(frame) = last_columns[frame] - first_columns[frame] + 1

    # Column-major in the file, and a picture here is row-major, so this is the one place the
    # two orders meet — the same crossing the walls make, over a sprite's see-through pixels.
    def pixels
      (top_row..bottom_row).flat_map do |y|
        @frames.flat_map do |frame|
          (0...SIDE).map do |x|
            value = frame[x, y]
            value.nil? ? :transparent : @palette[value]
          end
        end
      end
    end
  end
end
