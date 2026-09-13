# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # ONE LAYER'S TILES, ONCE THEY ARE STORED: what its map has to hold to name each of
        # them, where the layer counts its numbers from, and the number of its blank cell.
        StoredTiles = Data.define(:numbers, :base, :blank) do
          def number(index) = numbers.fetch(index)

          # The console is told where a layer's pictures begin as one of four 16K marks.
          def char_base = base / CHAR_BLOCK_BYTES
        end

        # WHAT EVERY BACKGROUND LAYER SHARES: one colour table and one run of tile pictures,
        # each uploaded whole at boot. +units+ are what a copy moves (halfwords), which is
        # what the upload wants; the rest is for the report.
        SharedScenery = Data.define(:palette_units, :tile_units, :small, :big, :saved, :shared, :skipped) do
          def tile_bytes = tile_units * 2
        end

        # EVERY TILE OF EVERY BACKGROUND, STORED ONCE EACH, as the one run of bytes the
        # console reads them out of. A layer is added to this and gets back the numbers its
        # map must hold; nothing else writes a tile picture.
        #
        # TWO TILES THAT COME OUT THE SAME ARE STORED ONCE. Nothing about a tileset says
        # which of its tiles are really the same picture — a wall's interior repeats in
        # every variation of that wall, half a metatile of grass is the same grass in
        # dozens of cells — and on a real tileset that is a large fraction. The author
        # writes the tileset they drew; the build notices. It costs nothing at run time,
        # because a tile number is a tile number.
        #
        # The sameness is judged on the STORED bytes rather than on the picture, which is
        # what makes it right rather than nearly right: two tiles drawn from different
        # colors are different pictures, and two identical pictures in layers that ended
        # up with different color banks are stored differently and must stay apart.
        #
        # Where the bytes go is {TileVram}'s (the tiles and the maps share 64K and grow
        # toward each other); this is what the bytes ARE.
        class BackgroundTiles
          def initialize(vram:)
            @vram = vram
            # Tile 0 is blank — every pixel the see-through number — so an empty map cell
            # points at a see-through tile and layers behind it show through. It has to be
            # readable BOTH ways, since a small-storage layer and a big-storage one can both
            # point at it: 64 zero bytes are 64 see-through pixels read as bytes and 128 read
            # as halves, so the big form covers the small one and one blank tile serves both.
            @bytes = (+"").b << ("\x00" * BIG_TILE_BYTES).b
            @vram.take_tile(BIG_TILE_BYTES)
            @stored = {} # the same picture, stored once — every place each one was put
            @shared = 0
            @skipped = 0
          end

          # The whole run, as it is uploaded; how many tiles turned out to be repeats; and
          # how many bytes nothing draws from (see #choose_base).
          attr_reader :bytes, :shared, :skipped

          # Put one layer's tiles in, and say how its map can name them. +drawn+ is the
          # layer's tiles in order, each the picture it was drawn from and where its colours
          # sit; +unit+ is how big one of this layer's tiles is stored (which is also the
          # step between one tile number and the next); +most+ is how many tiles its map can
          # count across.
          def add(name, drawn, unit:, most: TileVram::MOST_TILES)
            stored = drawn.map { |bmp, place| encode(bmp, place) }
            base = choose_base(stored, unit, most)

            # A layer counting from the bottom shares the blank tile seeded at 0. One
            # counting from anywhere else cannot see that far back, so it gets a blank of
            # its own — placed before its own tiles so it is the first thing in reach —
            # and its empty cells name that instead.
            blank = base.zero? ? 0 : place(name, ("\x00" * unit).b, unit, base, most)
            numbers = stored.each_with_index.to_h { |tile, index| [index, place(name, tile, unit, base, most)] }
            StoredTiles.new(numbers: numbers, base: base, blank: blank)
          end

          # Pack one 8x8 tile the way the tile hardware reads it: 64 pixels row by row,
          # each the number that picks its color. A tile stored the small way packs two
          # pixels into every byte, the left one in the low half — the same order a sprite
          # stored that way uses. (In this console's own words: 4bpp, low nibble first, so a
          # 4bpp tile is 32 bytes and an 8bpp one 64.)
          def encode(bmp, place)
            bytes = (+"").b
            pending = nil
            (TILE_PX * TILE_PX).times do |i|
              color = bmp.color_at(i)
              index = color == BG_SEE_THROUGH ? 0 : place.indices.fetch(color)
              next bytes << index.chr unless place.narrow?

              if pending.nil?
                pending = index
              else
                bytes << (pending | (index << 4)).chr
                pending = nil
              end
            end
            bytes
          end

          private

          # WHERE THIS LAYER COUNTS ITS TILE NUMBERS FROM, which decides how far it can
          # reach and is the whole reason a game can have more distinct tiles than one
          # layer's ten bits can name.
          #
          # Three answers, tried in order, and the first one that fits wins:
          #
          #   FROM THE BOTTOM, which is what every layer did before this existed. Nothing
          #   is skipped and the blank tile at 0 serves the empty cells. Nearly every game
          #   stops here, and gets exactly the layout it always got.
          #
          #   FROM THE BLOCK IT ALREADY STARTS IN — the highest 16K mark at or below where
          #   its tiles will land. Still nothing skipped, and the layer's reach moves up
          #   with it, so a second layer stacked on a big first one can point past the
          #   first layer's ceiling.
          #
          #   FROM THE NEXT BLOCK UP, which skips the few bytes in between. That is the
          #   only one that wastes anything, so it is last: it buys the layer a full run to
          #   itself, for at most 16K of memory nobody uses.
          #
          # Sharing follows the same rule as the reach: a picture already stored BELOW
          # where this layer counts from is out of its sight, so it stores its own copy
          # rather than pointing at one it cannot name.
          def choose_base(stored, unit, most)
            wanted = stored.uniq
            reach = most * unit
            mark = align(@vram.tile_bytes, unit)

            return 0 if mark + (fresh_bytes(wanted, 0, unit)) <= reach

            floor = (mark / CHAR_BLOCK_BYTES) * CHAR_BLOCK_BYTES
            return floor if mark + unit + fresh_bytes(wanted, floor, unit) <= floor + reach

            ceiling = align(mark, CHAR_BLOCK_BYTES)
            return floor if ceiling > TileVram::TOTAL_BYTES - CHAR_BLOCK_BYTES

            @skipped += ceiling - @vram.tile_bytes
            @vram.skip_to(ceiling)
            ceiling
          end

          # How much room this layer's pictures need if it counts from +base+: the ones no
          # copy of which is already stored somewhere it could name.
          def fresh_bytes(wanted, base, unit)
            wanted.count { |tile| stored_at(tile, base).nil? } * unit
          end

          # Where a picture already sits that a layer counting from +base+ could name. Two
          # layers counting from different places can each need their own copy, so what is
          # kept is every place a picture was stored, in the order they were stored.
          def stored_at(tile, base) = @stored.fetch(tile, []).find { |at| at >= base }

          # One tile's bytes, at the number a map will name it by — the place it already has
          # if this exact tile has been stored, else a fresh place at the end.
          def place(name, tile, unit, base, most)
            at = stored_at(tile, base)
            if at
              @shared += 1
            else
              at = @vram.take_tile(unit)
              @bytes << ("\x00" * (at - @bytes.bytesize)).b if at > @bytes.bytesize
              @bytes << tile
              (@stored[tile] ||= []) << at
            end
            @vram.tile_number(at, unit: unit, base: base, most: most) ||
              (raise LoweringError, too_far(name, at, unit, base, most))
          end

          # A map cell holds its tile number in ten bits, counted in the layer's own tile
          # size from wherever the layer starts counting — so it can name a run of 32K
          # stored the small way, 64K stored the big way, and each layer gets its own run.
          # Past that a tileset is not too big for the memory, it is too far for one map to
          # point across, and saying which is the difference between a fixable message and
          # a baffling one.
          def too_far(name, offset, unit, base, most)
            "background :#{name} counts its tiles from #{base} bytes into video memory and has one at " \
              "#{offset}, which is past the #{most * unit} bytes a map cell can reach across. Use fewer " \
              "different tiles, or declare this background before the ones with the biggest tilesets."
          end

          def align(value, to) = ((value + to - 1) / to) * to
        end
      end
    end
  end
end
