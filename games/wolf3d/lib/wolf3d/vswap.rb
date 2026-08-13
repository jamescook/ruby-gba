# frozen_string_literal: true

module Wolf3D
  # VSWAP: the wall textures, the sprites and the recorded sounds, in that order, with a header
  # saying where each kind starts.
  #
  # Everything is little-endian. The header is a chunk count, the index of the first sprite, the
  # index of the first sound, then a start and a length per chunk — so the three kinds are three
  # ranges of one list.
  class Vswap
    HEADER_BYTES = 6

    def self.from(game_data) = new(game_data.read("VSWAP"))

    def initialize(data)
      @data = data
      count, @first_sprite, @first_sound = data[0, HEADER_BYTES].unpack("v3")
      @starts = data[HEADER_BYTES, count * 4].unpack("V*")
      @lengths = data[HEADER_BYTES + (count * 4), count * 2].unpack("v*")
      @count = count
      check!
    end

    def wall_count = @first_sprite
    def sprite_count = @first_sound - @first_sprite
    def sound_count = sound_index.length

    def wall(index) = Texture.new(chunk(check_range(index, wall_count, "wall")))
    def sprite(index) = Sprite.new(chunk(@first_sprite + check_range(index, sprite_count, "sprite")))

    # A sound longer than a chunk runs across several, so the last chunk of the file is an index:
    # a starting chunk and a total length for each one.
    def sound(index)
      start, length = sound_index.fetch(check_range(index, sound_count, "sound"))
      Sound.new(gather(@first_sound + start, length))
    end

    def walls = (0...wall_count).map { |i| wall(i) }
    def sprites = (0...sprite_count).map { |i| sprite(i) }
    def sounds = (0...sound_count).map { |i| sound(i) }

    private

    def chunk(index) = @data[@starts[index], @lengths[index]]

    def gather(from, length)
      bytes = +"".b
      at = from
      while bytes.bytesize < length && at < @count
        bytes << chunk(at)
        at += 1
      end
      bytes[0, length]
    end

    def sound_index
      @sound_index ||= chunk(@count - 1).unpack("v*").each_slice(2).to_a
    end

    def check_range(index, limit, what)
      raise IndexError, "there is no #{what} #{index}; this file has #{limit}" unless index.between?(0, limit - 1)

      index
    end

    def check!
      raise ArgumentError, "VSWAP has no chunks" unless @count.positive?
      raise ArgumentError, "VSWAP's sprites start after its sounds" if @first_sprite > @first_sound
      raise ArgumentError, "VSWAP's chunk table runs past the file" if @starts.compact.max.to_i > @data.bytesize

      last = @starts[@count - 1] + @lengths[@count - 1]
      return if last <= @data.bytesize

      raise ArgumentError, "VSWAP says its last chunk ends at #{last} but the file is #{@data.bytesize} bytes"
    end

    # A wall: 64x64, one palette number a pixel, no compression — and stored COLUMN by column,
    # which is the order a first-person view reads it in. That is the one place this 1992 format
    # and the console agree for nothing.
    class Texture
      SIDE = 64
      BYTES = SIDE * SIDE

      def initialize(bytes)
        raise ArgumentError, "a wall is #{BYTES} bytes, got #{bytes.bytesize}" unless bytes.bytesize == BYTES

        @bytes = bytes
      end

      def column(x) = @bytes[x * SIDE, SIDE].bytes
      def [](x, y) = @bytes.getbyte((x * SIDE) + y)
      def to_s = @bytes
    end

    # A sprite: columns of runs, because most of one is empty. Two words say which columns are
    # not empty, then an offset per column into the runs, then the pixels, then the runs.
    #
    # Measured against a real file: the pixels sit BEFORE the runs and are read straight through
    # as the columns are walked, and they are padded to keep the runs on a word boundary.
    class Sprite
      SIDE = 64
      POST_WORDS = 3

      attr_reader :first_column, :last_column

      def initialize(chunk)
        @first_column, @last_column = chunk[0, 4].unpack("v2")
        @columns = Array.new(SIDE) { Array.new(SIDE) }
        decode(chunk)
      end

      # The column at x: 64 entries, each a palette number or nil where the sprite is see-through.
      def column(x) = @columns[x]
      def [](x, y) = @columns[x][y]

      def opaque_pixels = @columns.sum { |col| col.count { |v| !v.nil? } }

      private

      def decode(chunk)
        width = @last_column - @first_column + 1
        offsets = chunk[4, width * 2].unpack("v*")
        pool = 4 + (width * 2)

        offsets.each_with_index do |at, n|
          x = @first_column + n
          loop do
            finish, _unused, start = chunk[at, POST_WORDS * 2].unpack("v3")
            break if finish.nil? || finish.zero?

            (start / 2...finish / 2).each do |y|
              @columns[x][y] = chunk.getbyte(pool)
              pool += 1
            end
            at += POST_WORDS * 2
          end
        end
      end
    end

    # Raw 8-bit samples, and unsigned — which is the only conversion needed, since the framework
    # takes them centred on zero.
    class Sound
      RATE = 7000
      MIDPOINT = 128

      def initialize(bytes)
        @bytes = bytes
      end

      def length = @bytes.bytesize
      def rate = RATE
      def pcm = @bytes.bytes.map { |b| b - MIDPOINT }
    end
  end
end
