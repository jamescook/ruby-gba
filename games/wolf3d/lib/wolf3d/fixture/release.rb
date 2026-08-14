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

      # Columns of runs, because most of a sprite is empty. Measured against a real VSWAP: the
      # pixel pool sits BEFORE the posts, and is padded to keep the posts on a word boundary.
      #
      # ONE COLOUR EACH, and its number is the sprite's own. A real sprite is a picture, but a
      # fixture is for reading answers off, and a flat colour makes the pixel on the screen say
      # WHICH picture was drawn — which is how the eight poses of a guard are told apart.
      def sprite(index)
        first_col = 20
        last_col = 43
        columns = last_col - first_col + 1
        top = 16
        height = 32

        pool = Array.new(columns * height) { SPRITE_INK + index }.pack("C*")
        pool << "\x00" if pool.bytesize.odd?

        posts_at = 4 + (columns * 2) + pool.bytesize
        post = [(top + height) * 2, 0, top * 2].pack("v3") + [0].pack("v")
        offsets = Array.new(columns) { |i| posts_at + (i * post.bytesize) }

        [first_col, last_col].pack("v2") + offsets.pack("v*") + pool + (post * columns)
      end

      # Raw 8-bit unsigned samples, which is what the sample verb wants once 128 comes off.
      def sound(index)
        Array.new(512) { |i| (128 + (Math.sin(i * (index + 1) * 0.05) * 100).round) & 0xFF }.pack("C*")
      end

      # One dictionary for the whole file, so every chunk is packed with the same tree. The
      # first chunk is the picture table: a width and a height per picture.
      def vgagraph
        pictures = [[8, 8], [16, 4]]
        chunks = [pictures.flatten.pack("v*")]
        pictures.each_with_index { |(w, h), i| chunks << Array.new(w * h) { |p| (p + i) & 0xFF }.pack("C*") }

        tree = Codec::Huffman::Tree.for(chunks.join)
        bodies = chunks.map { |chunk| tree.pack(chunk) }

        graph = bodies.join
        at = 0
        offsets = bodies.map { |body| at.tap { at += body.bytesize } } << graph.bytesize
        [graph, tree.dictionary, three_byte(offsets)]
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
