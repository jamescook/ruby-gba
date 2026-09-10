# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHERE THE SCENERY'S PICTURES AND MAPS GO, and why they cannot land on each other.
        #
        # A tiled background is two separate things in video memory. The TILES are the
        # little pictures the scenery is built from — a brick, a patch of grass — stored
        # once each however many times they appear. The MAP is a grid saying which of them
        # goes in which cell. Both live in the same 64K, the console is told where each
        # begins, and pointing them at overlapping addresses does not fail: each writes
        # over the other, so the maps get drawn as if they were pictures and the picture
        # data gets read as tile numbers. It looks like confetti rather than like an error.
        #
        # So this hands both out, and it is the only thing that does.
        #
        # THEY GROW TOWARD EACH OTHER. Tiles are packed from the bottom, maps from the top
        # in units of 2K, and the build stops with an explanation when they would meet.
        # That is what lets a game with one enormous tileset and a game with four small
        # maps each use what they need, without the framework deciding in advance which
        # one it has. What it replaced was a fixed rule — tiles capped at the first 16K,
        # maps at fixed places just above — which gave a whole game 256 tiles however few
        # maps it had.
        #
        # WHAT LIMITS A TILESET, now that the fixed cap is gone, is how far a map can
        # POINT. A map cell holds a tile number in ten bits, counted in units of that
        # layer's own tile size — so a layer whose tiles are stored small (32 bytes each)
        # can name a run of 32K, and one stored the big way (64 bytes) a run of 64K. Both
        # are far past what the old rule gave.
        #
        # AND EACH LAYER COUNTS FROM ITS OWN STARTING POINT. That ten-bit number is an
        # offset from wherever the layer is told its pictures begin, and the console lets
        # each layer be told separately — one of four places 16K apart. So the reach is
        # per LAYER, not per game: one layer counting from the bottom can name the first
        # 32K while another counting from halfway names the last 32K, and between them
        # they use all of it. That is what lets a game with two big scrolling layers have
        # more distinct tiles than either one of them could name alone.
        #
        # Nothing hands out those starting points here, because picking one needs to know
        # how many tiles the layer is about to add and which of them are already stored —
        # see #choose_char_base in gba.rb. This class knows the bytes.
        class TileVram
          SCREEN_BLOCKS = 32
          SCREEN_BLOCK_BYTES = 0x800
          CHAR_BLOCK_BYTES = 0x4000
          TOTAL_BYTES = SCREEN_BLOCKS * SCREEN_BLOCK_BYTES

          # The four places a layer can be told its pictures begin, 16K apart.
          CHAR_BLOCKS = TOTAL_BYTES / CHAR_BLOCK_BYTES

          # A map cell holds its tile number in ten bits.
          MOST_TILES = 1024

          # Raised when the tiles and the maps would land on each other. The caller says
          # which tileset is the big one — this class knows the bytes, not the names.
          class Full < StandardError
            attr_reader :tile_bytes, :map_blocks

            def initialize(tile_bytes, map_blocks)
              @tile_bytes = tile_bytes
              @map_blocks = map_blocks
              super("the tiles and the maps do not both fit")
            end
          end

          def initialize
            @tile_bytes = 0  # how far the tiles have grown from the bottom
            @maps_taken = 0  # how many screen blocks the maps have taken from the top
          end

          # How far the tiles have grown, which is also where the next one would go.
          attr_reader :tile_bytes

          # Room for one tile, +unit+ bytes. Returns where it starts, in bytes from the
          # bottom — a map names it by that divided by the layer's own tile size, so a
          # tile has to start on one of those.
          def take_tile(unit)
            start = align(@tile_bytes, unit)
            @tile_bytes = start + unit
            check_they_still_fit!
            start
          end

          # Leave the tiles below +offset+ alone and grow from there instead. Used when a
          # layer takes a starting point of its own above where the last one stopped; the
          # bytes in between belong to nobody and are uploaded as zeroes.
          def skip_to(offset)
            @tile_bytes = offset if offset > @tile_bytes
            check_they_still_fit!
          end

          # Room for one map: +blocks+ consecutive screen blocks (one for a map of 32x32
          # cells, more for a larger one). Returns the first block's number.
          def take_map(blocks = 1)
            @maps_taken += blocks
            check_they_still_fit!
            SCREEN_BLOCKS - @maps_taken
          end

          # What a map has to hold to name the tile at +offset+, for a layer whose tiles
          # are +unit+ bytes each and which counts from +base+. Nil when it is out of that
          # layer's reach — below where it starts counting, or too far above it.
          def tile_number(offset, unit:, base: 0, most: MOST_TILES)
            return nil if offset < base

            number = (offset - base) / unit
            number < most ? number : nil
          end

          # What is left, for a report: the bytes neither the tiles nor the maps have
          # taken, and how many screen blocks the maps did take.
          def free_bytes = TOTAL_BYTES - @tile_bytes - (@maps_taken * SCREEN_BLOCK_BYTES)
          def map_blocks_taken = @maps_taken

          private

          def check_they_still_fit!
            first_map = (SCREEN_BLOCKS - @maps_taken) * SCREEN_BLOCK_BYTES
            return if @tile_bytes <= first_map && @maps_taken <= SCREEN_BLOCKS

            raise Full.new(@tile_bytes, @maps_taken)
          end

          def align(value, to) = ((value + to - 1) / to) * to
        end
      end
    end
  end
end
