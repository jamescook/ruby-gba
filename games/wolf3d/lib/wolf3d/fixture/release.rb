# frozen_string_literal: true

require "fileutils"

module Wolf3D
  module Fixture
    # A small release of our own, written in Wolfenstein's formats.
    #
    # Our content, so it commits freely and the tests can state exact bytes — a stronger check
    # than a real copy allows, where the best available assertion is that the counts look sane.
    class Release
      GRID = 64
      CELLS = GRID * GRID
      TEXTURE = 64
      RLEW_TAG = 0xABCD
      SIGNATURE = "TED5v1.0"
      LEVEL_SLOTS = 100
      LEVEL_HEADER_BYTES = 42
      NAME_BYTES = 16
      # Three offsets, three lengths, a width, a height, the name — and these four bytes, which
      # are what make the header 42 rather than 38.
      HEADER_END = "!ID!"

      # Plane 0 codes. The original numbers walls from 1 and starts floors at 108.
      FIRST_FLOOR = 108
      WALL = 1
      # A door's code says which way its panel runs, and the level must agree with where the
      # door actually is: both of these sit in a wall running east-west with wall to their east
      # and west, which is the odd code.
      DOOR = 91
      # ...and the gold-locked one, which sits in a wall running north-south, so it takes the
      # even code of its pair.
      GOLD_DOOR = Level::LOCKED_DOORS.first

      # Plane 1: where the player starts and which way they face, then everything standing in
      # the level.
      PLAYER_NORTH = 19
      GUARD_EAST = 108
      GOLD_KEY = Level::KEYS.key(:gold)

      attr_reader :dir, :set

      def self.write(dir, **) = new(**).write(dir)

      # Enough walls that the last eight can be the door pictures, the way a real release
      # arranges them, and a few real ones in front of those.
      DEFAULT_WALLS = Doors::DOOR_PICTURES + 4

      # ...and enough sprites to reach the last picture a guard can wear, which a real release
      # puts after its scenery. Everything before them is unused here, and small.
      DEFAULT_SPRITES = Guards.pictures.max + 1

      # Where a sprite's flat colour starts counting. Far enough up the palette to be clear of
      # the walls' inks, and low enough that every sprite of a default release has its own.
      SPRITE_INK = 150

      def initialize(set: "WL1", walls: DEFAULT_WALLS, sprites: DEFAULT_SPRITES, sounds: 2)
        @set = set
        @walls = walls
        @sprites = sprites
        @sounds = sounds
        @rlew = Codec::RLEW.new(tag: RLEW_TAG)
      end

      def write(dir)
        FileUtils.mkdir_p(dir)
        files.each { |stem, bytes| File.binwrite(File.join(dir, "#{stem}.#{@set}"), bytes) }
        @dir = dir
        self
      end

      def files
        maps, level_at = gamemaps
        graph, dictionary, head = vgagraph
        audio, audiohed = audiot

        { "MAPHEAD" => maphead(level_at), "GAMEMAPS" => maps, "VSWAP" => vswap,
          "VGADICT" => dictionary, "VGAGRAPH" => graph, "VGAHEAD" => head,
          "AUDIOHED" => audiohed, "AUDIOT" => audio }
      end

      # The release's art, read back the way the game reads it — for anything that wants a
      # picture by name rather than the bytes it was written as.
      def pictures
        graph, dictionary, head = vgagraph
        Vgagraph.new(graph: graph, dictionary: dictionary, head: head, set: @set)
      end

      # How far the inner room's walls stand from the middle. Close enough that a first-person
      # view meets one: a ray sees a handful of cells, so a player alone in a 64-cell field has
      # nothing to look at.
      ROOM = 4

      # A wall border round the whole map, a door in the north wall, and a small room around
      # the player in the middle — with one guard beside them.
      def plane0
        cells = Array.new(CELLS, FIRST_FLOOR)
        GRID.times do |y|
          GRID.times do |x|
            edge = x.zero? || y.zero? || x == GRID - 1 || y == GRID - 1
            cells[(y * GRID) + x] = WALL if edge || room_wall?(x, y)
          end
        end
        cells[GRID / 2] = DOOR
        # ...and one in the room's SOUTH wall, which the player starts with their back to. It
        # goes behind them rather than ahead so that the view forward stays a plain flat wall,
        # which is what the tests of the renderer itself measure.
        cells[(((GRID / 2) + ROOM) * GRID) + (GRID / 2)] = DOOR
        # The room's WEST wall holds a locked one, so a key has something to answer.
        cells[((GRID / 2) * GRID) + (GRID / 2) - ROOM] = GOLD_DOOR
        cells
      end

      # The four sides of the little room, and nothing inside it.
      def room_wall?(x, y)
        middle = GRID / 2
        dx = (x - middle).abs
        dy = (y - middle).abs
        (dx == ROOM && dy <= ROOM) || (dy == ROOM && dx <= ROOM)
      end

      # One in the room's EAST wall, level with the player, so walking straight at it reaches
      # it. It goes east rather than north or south so the wall ahead of the player and the
      # door behind them both stay as the renderer's own tests expect.
      def push_wall_cell = (((GRID / 2) * GRID) + (GRID / 2) + ROOM)

      # A key on the floor beside the player, and the locked door it answers.
      def key_cell = (((GRID / 2) - 1) * GRID) + (GRID / 2)

      def plane1
        cells = Array.new(CELLS, 0)
        middle = ((GRID / 2) * GRID) + (GRID / 2)
        cells[middle] = PLAYER_NORTH
        # Standing on the floor inside the room, two cells along, rather than in the wall.
        cells[middle + 2] = GUARD_EAST
        cells[push_wall_cell] = Level::PUSHWALL
        cells[key_cell] = GOLD_KEY
        cells
      end

      private

      def gamemaps
        body = +"".b
        body << SIGNATURE.b
        level_at = body.bytesize
        body << ("\x00".b * LEVEL_HEADER_BYTES)

        planes = [plane0, plane1, Array.new(CELLS, 0)].map do |cells|
          squeeze(cells.pack("v*")).tap { |packed| body << packed }
        end

        at = level_at + LEVEL_HEADER_BYTES
        offsets = planes.map { |packed| at.tap { at += packed.bytesize } }

        header = offsets.pack("V3") + planes.map(&:bytesize).pack("v3") +
                 [GRID, GRID].pack("v2") + "Fixture Room".b.ljust(NAME_BYTES, "\x00") + HEADER_END.b
        raise "the level header must be #{LEVEL_HEADER_BYTES} bytes" unless header.bytesize == LEVEL_HEADER_BYTES

        body[level_at, LEVEL_HEADER_BYTES] = header

        [body, level_at]
      end

      def maphead(level_at)
        offsets = Array.new(LEVEL_SLOTS, 0)
        offsets[0] = level_at
        [RLEW_TAG].pack("v") + offsets.pack("V*")
      end

      # RLEW first, then Carmack over the top, each preceded by how long it expands to.
      def squeeze(grid)
        Codec::Carmack.compress([grid.bytesize].pack("v") + @rlew.compress(grid))
      end

      # Walls, then sprites, then sounds — the header says where each kind starts. The last
      # chunk is the sound index.
      def vswap
        chunks = Array.new(@walls) { |i| wall_texture(i) }
        first_sprite = chunks.length
        @sprites.times { |i| chunks << sprite(i) }
        first_sound = chunks.length
        @sounds.times { |i| chunks << sound(i) }
        # The index counts from the FIRST SOUND, not from the start of the file — measured on a
        # real VSWAP, whose first pairs are [0, ...], [2, ...], [3, ...].
        chunks << Array.new(@sounds) { |i| [i, chunks[first_sound + i].bytesize] }.flatten.pack("v*")

        at = 6 + (chunks.length * 6)
        offsets = chunks.map { |chunk| at.tap { at += chunk.bytesize } }

        [chunks.length, first_sprite, first_sound].pack("v3") +
          offsets.pack("V*") + chunks.map(&:bytesize).pack("v*") + chunks.join
      end

      # Stored COLUMN by column, which is the order a raycaster reads them in. A border and a
      # diagonal, so a read that transposes the pixels is obvious rather than plausible.
      def wall_texture(index)
        ink = 16 + (index * 8)
        pixels = Array.new(TEXTURE * TEXTURE, ink)
        TEXTURE.times do |col|
          TEXTURE.times do |row|
            at = (col * TEXTURE) + row
            pixels[at] = ink + 4 if row == col
            pixels[at] = 0 if col.zero? || row.zero? || col == TEXTURE - 1 || row == TEXTURE - 1
          end
        end
        pixels.pack("C*")
      end

      # WHICH ROWS OF ITS SQUARE A SPRITE FILLS, as bands. Nearly everything here is one band
      # across the middle, which is what a thing standing on the floor in front of you looks
      # like.
      #
      # THE CEILING LIGHT IS THE ONE EXCEPTION, and it is the shape worth having: the lamp high
      # in the square, the light it throws low in it, and see-through nothing between. Anything
      # further off that lands in that gap is looked at THROUGH the lamp, so this is the piece
      # that asks whether one thing standing in a room can be seen past another.
      BAND = [[16, 48]].freeze
      HANGS = [[4, 20], [52, 60]].freeze

      def self.hanging_picture = Scenery.picture_of(Scenery::CEILING_LIGHT)

      # Columns of runs, because most of a sprite is empty. Measured against a real VSWAP: the
      # pixel pool sits BEFORE the posts, and is padded to keep the posts on a word boundary.
      #
      # ONE COLOUR EACH, and its number is the sprite's own. A real sprite is a picture, but a
      # fixture is for reading answers off, and a flat colour makes the pixel on the screen say
      # WHICH picture was drawn — which is how the eight poses of a guard are told apart. The
      # hanging one keeps that: both of its bands are the same colour, and only the gap differs.
      def sprite(index)
        first_col = 20
        last_col = 43
        columns = last_col - first_col + 1
        bands = index == self.class.hanging_picture ? HANGS : BAND
        rows = bands.sum { |top, bottom| bottom - top }

        pool = Array.new(columns * rows) { SPRITE_INK + index }.pack("C*")
        pool << "\x00" if pool.bytesize.odd?

        posts_at = 4 + (columns * 2) + pool.bytesize
        post = bands.map { |top, bottom| [bottom * 2, 0, top * 2].pack("v3") }.join + [0].pack("v")
        offsets = Array.new(columns) { |i| posts_at + (i * post.bytesize) }

        [first_col, last_col].pack("v2") + offsets.pack("v*") + pool + (post * columns)
      end

      # Raw 8-bit unsigned samples, which is what the sample verb wants once 128 comes off.
      def sound(index)
        Array.new(512) { |i| (128 + (Math.sin(i * (index + 1) * 0.05) * 100).round) & 0xFF }.pack("C*")
      end

      # THE PICTURES, and their widths divide by four on purpose — the display these were
      # drawn for held every fourth column in a bank of its own, so a picture is stored as
      # four quarter-width pictures stacked. A width that did not divide by four could not
      # be stored at all, so writing one here would teach the reader a shape that cannot
      # happen.
      PICTURES = [[8, 4], [16, 2]].freeze

      # --- A RELEASE WHOSE PICTURES HAVE NAMES ---------------------------------------------
      #
      # WHAT A PICTURE IS CALLED is the one thing that really differs from release to release,
      # and the reader keeps a table of it — so the status bar reaches the face and the
      # numerals by name. A fixture of a set nobody has named carries none of that, and the
      # bar's own art can then only be tested against somebody's copy of the game.
      #
      # So a fixture written as a set the reader HAS named puts its pictures at the numbers
      # those names point at. The names are read out of the reader's table rather than kept
      # here, which is what keeps the arrangement one-way: this follows the reader, and
      # nothing in the reader knows a fixture exists.
      def named = Vgagraph::NAMES.fetch(@set, {})

      # THE SIZES THE NAMED PICTURES REALLY ARE, off a copy of the six-episode release. Three
      # of them decide how the bar is laid out — the plate, the numerals and the faces are
      # what the fields are spread across 240 pixels BY — so a fixture that made them up would
      # arrange a different bar from the one a player sees.
      FULL_SCREEN = [320, 200].freeze
      WEAPON = [48, 24].freeze
      # A key, a numeral, and the blank one that stands in for a leading nought.
      SLOT = [8, 16].freeze
      FACE = [24, 32].freeze

      # ...and everything else is the smallest picture that can be stored, since a width has
      # to divide by four. They are there to hold their places in the picture table, which is
      # the only part of a release that has to be the right length.
      STAND_IN = [4, 1].freeze

      # Every picture this release carries, as a width and a height. A named one reaches as
      # far as the last name; a real release carries a few more after that, which nothing
      # asks for.
      def picture_sizes
        return PICTURES if named.empty?

        by_number = named.invert
        Array.new(named.values.max + 1) { |n| size_of(by_number[n]) }
      end

      def size_of(name)
        case name
        when nil then STAND_IN
        when :status_bar then PLATE
        when :title, :credits then FULL_SCREEN
        when :notice then [88, 64]
        when :high_scores then [224, 56]
        when :knife, :pistol, :machine_gun, :chain_gun then WEAPON
        else name.start_with?("face_") ? FACE : SLOT
        end
      end

      # THE TWO ALPHABETS, and both are PROPORTIONAL on purpose: a reader that assumed one
      # width for the whole font would find the second character in the wrong place and
      # still come back with something that looked like letters.
      FONTS = [
        { height: 3, glyphs: { "I" => %w[# # #], "M" => ["# #", "###", "# #"] } },
        { height: 5, glyphs: { "L" => ["#.", "#.", "#.", "#.", "##"] } }
      ].freeze

      # What a lit pixel of a glyph holds. Anything but zero is ink; the colour is chosen
      # when the game writes, not when the alphabet was drawn.
      FONT_INK = 0xFF

      # One dictionary for the whole file, so every chunk is packed with the same tree. The
      # chunks are laid out the way a release lays them out: the picture table, then the
      # two fonts, then the pictures. Each one carries how long it comes out in four bytes
      # in front of the packing, because the packing does not say where it stops.
      def vgagraph
        @vgagraph ||= begin
          sizes = picture_sizes
          chunks = [sizes.flatten.pack("v*")]
          FONTS.each { |font| chunks << font_chunk(font) }
          sizes.each_with_index { |(w, h), i| chunks << picture_chunk(w, h, i) }

          tree = Codec::Huffman::Tree.for(chunks.join)
          bodies = chunks.map { |chunk| [chunk.bytesize].pack("V") + tree.pack(chunk) }

          graph = bodies.join
          at = 0
          offsets = bodies.map { |body| at.tap { at += body.bytesize } } << graph.bytesize
          [graph, tree.dictionary, three_byte(offsets)]
        end
      end

      # WHAT A PIXEL HOLDS: its own row in the top four bits and its own column in the
      # bottom four. So a reader that shuffled the four banks, or read the picture down
      # instead of across, comes back with a number that says where it really went — which
      # a picture of a pattern would only hint at.
      def picture_pixel(x, y) = (y << 4) | x

      # ...AND WHEN THERE ARE NAMES, WHICH PICTURE IT IS AS WELL. Where a picture only has to
      # come out of its four banks in order, saying the row and the column is enough. The
      # named ones are read out of a ROW of pictures laid side by side — twenty-four faces,
      # eleven numerals — and there the question is which of them landed, so a pixel has to
      # answer that too.
      #
      # It holds its picture's own number plus how far into the picture it is, counted along
      # the rows. A face read at the wrong number comes back shifted by the difference between
      # the two, and one read at the wrong place along the row comes back shifted by that: the
      # pixel names where it really came from either way, which is the whole reason to write a
      # fixture instead of testing against a real copy.
      def named_pixel(index, at) = (index + at) & 0xFF

      # Stored bank by bank: the first holds columns 0, 4, 8..., the second columns 1, 5,
      # 9..., and each bank is a whole quarter-width picture of its own.
      def picture_chunk(width, height, index)
        quarter = width / 4
        4.times.flat_map { |bank|
          height.times.flat_map { |y| quarter.times.map { |i| pixel_of(index, (i * 4) + bank, y, width) } }
        }.pack("C*")
      end

      def pixel_of(index, x, y, width)
        return picture_pixel(x, y) if named.empty?
        return plate[y][x] if index == named[:status_bar]

        named_pixel(index, (y * width) + x)
      end

      # --- THE STEEL PLATE ALONG THE BOTTOM ------------------------------------------------
      #
      # THE ONE PICTURE HERE WHOSE ARRANGEMENT MATTERS RATHER THAN ITS PIXELS. The bar does
      # not read the plate for a picture, it reads it for a LAYOUT: a line along the top and
      # the bottom, a dark column between each pair of fields, and the word inside each field.
      # It works all three out by looking rather than by remembering numbers, so a plate that
      # is not built out of those parts comes back with no fields on it at all.
      #
      # The columns are the release's own, which is what makes the bar this lays out the same
      # bar a real copy lays out — and the bar has no give in it: seven fields and the gaps
      # between them have to come to 240.
      PLATE = [320, 40].freeze

      # WHERE THE PLATE IS DIVIDED: the frame down each side, a groove between each pair of
      # fields, and the well the face sits in — which is wide, and which the reader reads as a
      # divider like any other. What lies between them are the fields.
      PLATE_DIVIDERS = [0..9, 41..42, 99..100, 132..165, 203..204,
                        239..240, 247..248, 310..319].freeze

      # How far down a divider runs: everything between the two edges and no further. It has
      # to be dark for most of the plate's height, because that is how a groove is told from a
      # field.
      PLATE_INSIDE = (4..35)

      # The rows of the plate's own edge, outermost first at each end. Two colours at each,
      # which is what makes an edge read as a bevel in the metal rather than as a line drawn
      # round it.
      PLATE_EDGES = { (0..1) => 16, (2..3) => 17, (36..37) => 18, (38..39) => 19 }.freeze

      # The rows the words are painted on, and how wide each word comes to. Both are the
      # release's own: the bar is laid out from the width of what goes in it, so words of a
      # width we made up would spread the fields differently from the way a player sees them.
      PLATE_WORD_ROWS = (6..14)
      PLATE_WORDS = { floor: 26, score: 27, lives: 24, health: 33, ammo: 26 }.freeze

      # The ground the plate is painted on, and the two colours a groove is cut in. Ours
      # rather than the release's, and far enough apart in the palette that nothing on the
      # plate can be mistaken for anything else on it.
      PLATE_GROUND = 24
      PLATE_RULE = [40, 44].freeze

      # A WORD IS PAINTED IN A BAND OF ITS OWN, and a different colour on each of its rows. So
      # a word cut from the wrong field comes back in the wrong band, and one cut a row out of
      # place comes back in the wrong order — where a word in one flat colour would look right
      # either way.
      PLATE_WORD_INK = 96
      PLATE_WORD_BAND = 16

      def plate
        @plate ||= begin
          width, height = PLATE
          rows = Array.new(height) { Array.new(width, PLATE_GROUND) }
          PLATE_EDGES.each { |ys, ink| ys.each { |y| rows[y] = Array.new(width, ink) } }
          PLATE_DIVIDERS.each do |columns|
            PLATE_INSIDE.each { |y| columns.each { |x| rows[y][x] = PLATE_RULE[x % 2] } }
          end
          PLATE_WORDS.each_with_index { |(_name, wide), n| paint_word(rows, n, wide) }
          rows
        end
      end

      # The fields: what lies between one divider and the next. The first five carry the words
      # the bar cuts out of the plate; the two after them hold the keys and the weapon, which
      # the original leaves unlabelled.
      def plate_fields
        PLATE_DIVIDERS.each_cons(2).map { |before, after| (before.last + 1)..(after.first - 1) }
      end

      def paint_word(rows, field, wide)
        columns = plate_fields.fetch(field)
        from = columns.first + ((columns.count - wide) / 2)
        PLATE_WORD_ROWS.each_with_index do |y, dy|
          wide.times { |dx| rows[y][from + dx] = PLATE_WORD_INK + (field * PLATE_WORD_BAND) + dy }
        end
      end

      # A font's heading is a height, then where each of the 256 characters starts inside
      # the chunk, then how wide each one is — and a character nobody drew is nought wide.
      # The lettering follows, one byte a pixel, read across the rows.
      def font_chunk(font)
        height = font.fetch(:height)
        widths = Array.new(256, 0)
        locations = Array.new(256, 0)
        lettering = +"".b

        font.fetch(:glyphs).each do |char, art|
          code = char.ord
          widths[code] = art.first.length
          locations[code] = Vgagraph::Font::HEADER_BYTES + lettering.bytesize
          art.each { |row| lettering << row.each_char.map { |px| px == "#" ? FONT_INK : 0 }.pack("C*") }
        end

        [height].pack("v") + locations.pack("v*") + widths.pack("C*") + lettering
      end

      def audiot
        chunks = [Array.new(8) { |i| i }.pack("C*")]
        body = chunks.join
        at = 0
        offsets = chunks.map { |chunk| at.tap { at += chunk.bytesize } } << body.bytesize
        [body, offsets.pack("V*")]
      end

      # VGAHEAD stores three-byte offsets, not four.
      def three_byte(offsets)
        offsets.flat_map { |o| [o & 0xFF, (o >> 8) & 0xFF, (o >> 16) & 0xFF] }.pack("C*")
      end
    end
  end
end
