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
  # A GUN HANGS AT THE BOTTOM OF THE SCREEN, so the top of its square is empty in every one of
  # the twenty — over a third of it, and much more than that for a knife held still. The picture
  # here is the WHOLE SQUARE all the same, and that is the opposite of what it looks like it
  # should be. It is worth its paragraph, because the obvious thing is measurably wrong.
  #
  # Cropping the empty rows away was tried: ship the band that holds art, put it where the
  # square's rows would have fallen, and the walk down the screen never sees the sky. It bought
  # no time at all, because the framework was already skipping those rows and far better than a
  # band can — it ships, for each COLUMN of a see-through picture, the stretches of rows that
  # hold pixels, and walks those and nothing else. That is the same trick the original's own
  # scaler uses. The sky above the gun is not what a crop saves; nothing was walking it.
  #
  # WHAT THE CROP COSTS is the divide. Turning a picture row into a screen row divides by the
  # picture's height, and a height that is a power of two divides by shifting where any other
  # multiplies — one more instruction and a longer one, twice per stretch. Measured against the
  # whole square on the real pictures, the crop is a little dearer rather than a little cheaper.
  # Sixty-four is a power of two, so the square ships whole, the walk touches the gun and not the
  # sky, and the arithmetic is the cheap one.
  #
  # A picture that cannot ship its stretches at all — one over the framework's row ceiling — is
  # named by `rom.explain`, with what to change.
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

    def width = COUNT * SIDE
    def height = SIDE

    # WHICH ROWS OF THE SQUARE ANY FRAME HOLDS ART IN, which nothing about the drawing reads —
    # the whole square is drawn and the framework skips the empty rows for itself. It is here
    # because it is the fact that makes cropping look like a good idea (see the note above), and
    # because a test that wants to find the gun on the screen has to know where it hangs.
    def art_rows = @art_rows ||= (@frames.map(&:first_row).min..@frames.map(&:last_row).max)

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
      (0...SIDE).flat_map do |y|
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
