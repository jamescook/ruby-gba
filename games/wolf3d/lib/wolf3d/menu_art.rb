# frozen_string_literal: true

module Wolf3D
  # WOLFENSTEIN'S OWN ART FOR EVERYTHING YOU MEET BEFORE YOU PLAY, out of VGAGRAPH and ready
  # to hand to the framework: the title screen, the credits, the rating box, the plate over
  # the menu's rows, the gun it points with, and the four portraits of the difficulty screen.
  #
  # NOTHING HERE IS SEE-THROUGH, and that is not an accident of this file — Wolfenstein has no
  # see-through pictures at all, which is why its menus erase the gun with a filled bar rather
  # than putting back what was under it. So every picture below is drawn solid, which is also
  # the only kind the double-buffered screen can draw.
  #
  # THE TWO FULL-SCREEN PICTURES ARE THE ONE PIECE OF WORK. The title and the credits were
  # painted 320x200 for a display this console does not have; the screen here is 240x160. So
  # eighty columns and forty rows have to go — and the answer is different for each, because
  # the picture has room to spare down it and none at all across it.
  #
  # THE ROWS ARE FREE. Seventy-two of the credits' two hundred rows are completely empty — the
  # spaces between the lines of names — and only forty need to go. So the picture is made
  # shorter by taking out the emptiest rows, one at a time, and NOTHING is lost. The title
  # screen is a painting with no empty rows, so it gives up its forty flattest instead, which
  # on a painting nobody can see.
  #
  # THE COLUMNS ARE NOT FREE, and this is what three attempts taught. The credits' lettering
  # reaches from column 9 to column 313 — three hundred and five columns of content for a
  # screen two hundred and forty wide — so sixty-five columns have to come out of the writing
  # itself, however cleverly they are chosen. Every stroke of that lettering is two pixels
  # wide, and a stroke that loses one of them is a stroke one pixel wide: the end of a word
  # goes to mush. Dropping every fourth column was the worst of it; choosing the quietest was
  # better and still not good; averaging the pixels that merge fixed the outlines and left
  # every stroke thinned, which is most of the damage.
  #
  # SO THE COLUMNS ARE NOT TOUCHED AT ALL. The picture keeps the full width it was painted at
  # and the SCREEN moves across it instead — see Menus, which drifts the window over the
  # eighty columns that do not fit. Every letter arrives exactly as it was painted, and the
  # attract loop gets some movement back, which is the one thing it lost with the recorded
  # demo the original plays and this cannot.
  class MenuArt
    # What the console's screen is. A picture wider than this is not squeezed to fit it; the
    # window is moved across the picture instead.
    ACROSS = 240
    DOWN = 160

    # The pictures that were painted for the whole of that bigger screen.
    FULL_SCREEN = %i[title credits].freeze

    # +vgagraph+ is a release whose pictures have names. Nil for a release we cannot name, and
    # then there are no menus in the game's own art to draw.
    def self.of(vgagraph)
      new(vgagraph) if vgagraph && vgagraph.names.include?(:menu_gun)
    end

    def initialize(vgagraph)
      @vg = vgagraph
    end

    # ONE PICTURE, as the framework's `image` wants it: a width, a height, and its pixels as
    # colours rather than as numbers into Wolfenstein's table.
    def picture(name, palette)
      pic = @vg.picture(name)
      return shortened(pic, palette) if FULL_SCREEN.include?(name)

      { width: pic.width, height: pic.height,
        data: pic.rows.flat_map { |row| row.map { |ink| palette[ink] } } }
    end

    # How big a picture comes out, without decoding it — which is what a screen laying itself
    # out needs, and it needs it before there is anything to draw. A picture painted for a
    # bigger screen keeps its WIDTH; only its height is brought down.
    def size(name)
      return [@vg.size(name).first, DOWN] if FULL_SCREEN.include?(name)

      @vg.size(name)
    end

    def width(name) = size(name).first
    def height(name) = size(name).last

    # ONE OF THE TWO ALPHABETS, as pictures of its letters, ready for `font ..., glyphs:`. The
    # small one (0) is what the menus are written in and the big one (1) is for a heading. Both
    # are PROPORTIONAL — every character carries its own width — which the framework's own font
    # model already handles, so there is nothing to do here but hand them over.
    def font(which) = @vg.font(which).glyphs

    private

    # SHORTER, AND NOT NARROWER. Every column is kept, so nothing across the picture is ever
    # squeezed; the window is moved over it instead.
    def shortened(pic, palette)
      unless pic.height >= DOWN
        raise ArgumentError,
              "A picture #{pic.height} rows tall is shorter than this #{DOWN}-row screen. " \
              "Only a picture painted taller has rows to give up."
      end

      rows = keep(pic, brightness_of(palette), pic.height - DOWN)
      { width: pic.width, height: DOWN,
        data: rows.flat_map { |y| (0...pic.width).map { |x| palette[pic[x, y]] } } }
    end

    # WHICH ROWS SURVIVE: take the emptiest, ONE AT A TIME, and after each one ask again.
    #
    # Asking again is the whole of it. Take the forty emptiest all at once and they arrive in
    # clumps, because a run of rows through the same empty band all score alike — and several
    # taken from between two lines of writing push those lines into each other. Taken one at a
    # time, the moment a row goes its two neighbours become NEIGHBOURS, and if that closed a gap
    # up they now differ sharply, so the next removal goes somewhere else. On the credits it
    # never has to choose: seventy-two of the rows are completely empty and only forty go.
    #
    # An edge of the picture is never taken: it has nothing above it to differ from.
    def keep(pic, light, count)
      rows = (0...pic.height).to_a
      carried = rows.map { |y| y.zero? ? nil : gap(pic, light, y, y - 1) }
      count.times do
        at = (1...rows.length).min_by { |n| [carried[n], n] }
        rows.delete_at(at)
        carried.delete_at(at)
        carried[at] = gap(pic, light, rows[at], rows[at - 1]) if at < rows.length
      end
      rows
    end

    # HOW DIFFERENT TWO ROWS ARE, added along their whole width. Flat ground scores nothing
    # whatever colour it is; the edge of a letter scores a great deal.
    def gap(pic, light, a, b)
      (0...pic.width).sum { |x| (light[pic[x, a]] - light[pic[x, b]]).abs }
    end

    # How light each of the game's colours is, worked out once for the whole picture. The
    # console holds five bits a channel, so this is a number from 0 to 93.
    def brightness_of(palette)
      Array.new(palette.length) do |ink|
        colour = palette[ink]
        (colour & 31) + ((colour >> 5) & 31) + ((colour >> 10) & 31)
      end
    end
  end
end
