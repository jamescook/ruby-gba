# frozen_string_literal: true

module Wolf3D
  # The levels, read out of MAPHEAD and GAMEMAPS.
  #
  # MAPHEAD is the run tag and a slot per level; a slot that is zero is a level that was never
  # made. Each used slot points at a 42-byte header in GAMEMAPS, and each of that header's
  # planes is squeezed twice — Carmack over RLEW — so it comes back the other way round.
  class Maps
    HEADER_BYTES = 42
    HEADER_END = "!ID!"
    NAME_AT = 22
    NAME_BYTES = 16
    PLANES = 3
    WALLS = 0
    THINGS = 1

    def self.from(game_data)
      new(maphead: game_data.read("MAPHEAD"), gamemaps: game_data.read("GAMEMAPS"))
    end

    def initialize(maphead:, gamemaps:)
      @gamemaps = gamemaps
      @rlew = Codec::RLEW.new(tag: maphead[0, 2].unpack1("v"))
      @offsets = maphead[2..].unpack("V*").take_while(&:positive?)
      @levels = {}
    end

    def count = @offsets.length

    def [](index)
      raise IndexError, "there is no level #{index}; this release has #{count}" unless index.between?(0, count - 1)

      @levels[index] ||= decode(@offsets[index])
    end

    def each
      return enum_for(:each) unless block_given?

      count.times { |i| yield self[i] }
    end

    def names = count.times.map { |i| self[i].name }

    private

    def decode(offset)
      header = @gamemaps[offset, HEADER_BYTES]
      raise ArgumentError, "the level header at #{offset} does not end in #{HEADER_END}" unless
        header[38, 4] == HEADER_END

      starts = header[0, 12].unpack("V#{PLANES}")
      lengths = header[12, 6].unpack("v#{PLANES}")
      width, height = header[18, 4].unpack("v2")

      Level.new(name: header[NAME_AT, NAME_BYTES].unpack1("Z*"), width: width, height: height,
                walls: plane(starts[WALLS], lengths[WALLS], width * height),
                things: plane(starts[THINGS], lengths[THINGS], width * height))
    end

    # Carmack first, then RLEW. Each carries how long it expands to in its own first word, and
    # both are checked rather than trusted.
    def plane(at, length, cells)
      carmacked = Codec::Carmack.expand(@gamemaps[at, length])
      wanted = carmacked[0, 2].unpack1("v")
      grid = @rlew.expand(carmacked[2..])

      raise ArgumentError, "a plane said it was #{wanted} bytes and came out #{grid.bytesize}" unless
        grid.bytesize == wanted
      raise ArgumentError, "a plane came out #{grid.bytesize / 2} cells, wanted #{cells}" unless
        grid.bytesize == cells * 2

      grid.unpack("v*")
    end
  end
end
