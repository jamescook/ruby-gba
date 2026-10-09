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

        # WHAT EVERY BACKGROUND LAYER SHARES: one colour table, uploaded whole at boot, and the
        # tile pictures of the scenery every screen shows, uploaded with it. +units+ are what a
        # copy moves (halfwords), which is what the upload wants; the rest is for the report.
        #
        # +tile_bytes+ is the busiest screen's pictures, which is not what boot sends: a scene's
        # own pictures go in as it takes over, into room the other scenes use too, so what has
        # to fit — and what is worth reporting — is the one screen that holds the most.
        SharedScenery = Data.define(:palette_units, :tile_units, :tile_bytes, :small, :big, :saved, :shared, :mirrored,
                                   :skipped)

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
            @mirrored = 0
            @skipped = 0
          end

          # A COPY TO GO ON FROM, for scenery that takes turns. Two scenes that are never on
          # screen together can put their pictures in the same room, so each goes on from
          # what every scene shares and neither sees the other's. The copy has room of its
          # own to hand out as well as pictures, since that is the half that is shared.
          def initialize_copy(from)
            super
            @vram = from.vram.dup
            @bytes = from.bytes.dup
            @stored = from.stored.transform_values(&:dup)
            @painted_at = from.painted_at.dup
          end

          # The whole run, as it is uploaded; how many tiles turned out to be repeats; how many
          # turned out to be another tile mirrored; and how many bytes nothing draws from (see
          # #choose_base).
          attr_reader :bytes, :shared, :mirrored, :skipped

          # The room this run is laid out in, which the maps are handed out of as well.
          attr_reader :vram

          protected

          attr_reader :stored

          public

          # Put one layer's tiles in, and say how its map can name them. +drawn+ is the
          # layer's tiles in order, each the picture it was drawn from and where its colours
          # sit; +unit+ is how big one of this layer's tiles is stored (which is also the
          # step between one tile number and the next); +most+ is how many tiles its map can
          # count across.
          #
          # +mirrors+ says the layer's map can draw a tile reversed (see #mirrors_of). A
          # turning layer's cells have no room to say so, and keeps a mirror as a picture.
          #
          # +painted+ names the tiles, by their index in +drawn+, whose pixels the game paints
          # from a list as it runs (see Nodes::TileRun). They are never shared, with each other
          # or anything else — two that are blank now will not be on the next frame — and where
          # each one landed is kept, for the copy that paints it (see #painted_at).
          def add(name, drawn, unit:, most: TileVram::MOST_TILES, painted: {}, mirrors: false)
            @mirrors = mirrors
            stored = drawn.map { |bmp, place| encode(bmp, place) }
            pictures = stored.reject.with_index { |_, i| painted.key?(i) }
            distinct = pictures.uniq
            @layer_mirrors = mirrors ? distinct.size - distinct.uniq { |tile| mirror_group(tile, unit) }.size : 0
            base = choose_base(pictures, unit, most, unshared: painted.size)

            # A layer counting from the bottom shares the blank tile seeded at 0. One
            # counting from anywhere else cannot see that far back, so it gets a blank of
            # its own — placed before its own tiles so it is the first thing in reach —
            # and its empty cells name that instead.
            blank = base.zero? ? 0 : store_tile(name, ("\x00" * unit).b, unit, base, most)
            numbers = stored.each_with_index.to_h do |tile, index|
              image = painted[index]
              [index, image ? store_painted_tile(name, image, tile, unit, base, most) : store_tile(name, tile, unit, base, most)]
            end
            StoredTiles.new(numbers: numbers, base: base, blank: blank)
          end

          # ONE LAYER DRAWN FROM SEVERAL SETS OF TILES, only one of which is in video memory at a
          # time: an area's tiles, swapped for the next area's as the game walks between them.
          #
          # Every set goes in the SAME room, starting where this run has got to, so the room
          # this layer takes is its biggest set's and not all of them together — which is the
          # whole point, since the sets together need not fit. Each set may share a picture
          # already stored below it, because nothing below ever changes; but nothing stored
          # after this layer may share one of a set's pictures, because the picture in that
          # place changes as the sets do. So the sets are laid out in copies of this run, and
          # this run takes only their room, and the first set's bytes, which are what is in
          # place when the layer first goes up.
          #
          # Returns where the room starts, and for each set how its map names its tiles and the
          # bytes that go in the room when that set is brought in.
          SetTiles = Data.define(:start, :stored, :bytes)

          def add_sets(name, drawn_sets, unit:, most: TileVram::MOST_TILES)
            pad_to(@vram.tile_bytes)
            start = @bytes.bytesize
            laid = drawn_sets.map do |drawn|
              copy = dup
              [copy.add(name, drawn, unit: unit, most: most, mirrors: true), copy]
            end
            room = laid.map { |_, copy| copy.vram.tile_bytes }.max
            bytes = laid.map { |_, copy| copy.pad_to(room).bytes.byteslice(start..) }
            @vram.skip_to(room)
            @bytes << bytes.first
            @shared += laid.sum { |_, copy| copy.shared - @shared }
            @mirrored += laid.sum { |_, copy| copy.mirrored - @mirrored }
            SetTiles.new(start: start, stored: laid.map(&:first), bytes: bytes)
          end

          # Grow the run with nothing to +offset+, where it falls short of it.
          def pad_to(offset)
            @bytes << ("\x00" * (offset - @bytes.bytesize)).b if offset > @bytes.bytesize
            self
          end

          # Where each painted tile landed, as bytes into video memory, by its picture's name.
          def painted_at = (@painted_at ||= {})

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
              # A tile that got a BANK of sixteen stores the place in the author's own list,
              # which is the number the console reads. One stored the big way reads the whole
              # shared table, where the same color is one entry however many places the list
              # gave it — so there is nothing to keep apart and the color is looked up.
              # Black at a place of its own is a real color, so it was given a slot like the
              # rest; only a pixel the tile leaves empty takes the see-through number.
              index = (place.narrow? && bmp.place_at(i)) ||
                      (bmp.tile_see_through_at?(i) ? 0 : place.indices.fetch(color))
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
          #
          # +unshared+ is how many painted tiles come too, each needing room of its own.
          def choose_base(stored, unit, most, unshared: 0)
            wanted = @mirrors ? stored.uniq { |tile| mirror_group(tile, unit) } : stored.uniq
            reach = most * unit
            mark = align(@vram.tile_bytes, unit)
            own = unshared * unit

            return 0 if mark + fresh_bytes(wanted, 0, unit) + own <= reach

            floor = (mark / CHAR_BLOCK_BYTES) * CHAR_BLOCK_BYTES
            return floor if mark + unit + fresh_bytes(wanted, floor, unit) + own <= floor + reach

            ceiling = align(mark, CHAR_BLOCK_BYTES)
            return floor if ceiling > TileVram::TOTAL_BYTES - CHAR_BLOCK_BYTES

            @skipped += ceiling - @vram.tile_bytes
            @vram.skip_to(ceiling)
            ceiling
          end

          # How much room this layer's pictures need if it counts from +base+: the ones no
          # copy of which is already stored somewhere it could name.
          def fresh_bytes(wanted, base, unit)
            wanted.count { |tile| stored_place_and_flip(tile, base, unit).nil? } * unit
          end

          # Where a picture can be drawn from by a layer counting from +base+, and which way
          # round: the picture itself if it is stored, else one of its mirrors drawn reversed.
          # Nil when neither is.
          def stored_place_and_flip(tile, base, unit)
            at = stored_at(tile, base)
            return [at, 0] if at
            return nil unless @mirrors

            mirrors_of(tile, unit).each do |flip, picture|
              at = stored_at(picture, base)
              return [at, flip] if at
            end
            nil
          end

          # One answer for a tile and all its mirrors, so they count as one picture.
          def mirror_group(tile, unit) = [tile, *mirrors_of(tile, unit).values].min

          # The three other ways round a tile can be drawn, as the bytes each would be stored as,
          # by the map bits that turn the stored one into it. Reversing a picture is its own
          # undoing, so the bits that draw a mirror from the tile also draw the tile from it.
          #
          # A row is a tile's width in bytes: eight for a tile stored the big way, one pixel a
          # byte, and four for one stored small, two pixels a byte with the left one in the low
          # half — so reversing a small row reverses its bytes AND swaps the halves of each.
          def mirrors_of(tile, unit)
            width = unit / TILE_PX
            rows = tile.bytes.each_slice(width).to_a
            across = rows.map do |row|
              row = row.reverse
              width == TILE_PX ? row : row.map { |byte| ((byte & 0x0F) << 4) | (byte >> 4) }
            end
            { BG_FLIP_ACROSS => across, BG_FLIP_DOWN => rows.reverse,
              BG_FLIP_ACROSS | BG_FLIP_DOWN => across.reverse }
              .transform_values { |picture| picture.flatten.pack("C*") }
          end

          # Where a picture already sits that a layer counting from +base+ could name. Two
          # layers counting from different places can each need their own copy, so what is
          # kept is every place a picture was stored, in the order they were stored.
          def stored_at(tile, base) = @stored.fetch(tile, []).find { |at| at >= base }

          # One tile's bytes, at the number a map will name it by — the place it already has
          # if this exact tile or a mirror of it has been stored (the mirror drawn turned round),
          # else a fresh place at the end.
          def store_tile(name, tile, unit, base, most)
            at, flip = stored_place_and_flip(tile, base, unit)
            if at
              flip.zero? ? @shared += 1 : @mirrored += 1
            else
              flip = 0
              at = @vram.take_tile(unit)
              @bytes << ("\x00" * (at - @bytes.bytesize)).b if at > @bytes.bytesize
              @bytes << tile
              (@stored[tile] ||= []) << at
            end
            number = @vram.tile_number(at, unit: unit, base: base, most: most) ||
                     (raise LoweringError, too_far_message(name, at, unit, base, most))
            number | flip
          end

          # A painted tile's bytes, at a place of its own and never offered to anything that
          # comes after as a picture to share. The one thing it does share is ITSELF: a run
          # this screen already holds — another background showing it, or the scenery every
          # screen shows — is pointed at where it is, since the game paints it in one copy and
          # one screen can only hold it in one place. (A copy too far back for this layer to
          # name is the exception, and stores again; the layout then refuses the two places.)
          def store_painted_tile(name, image, tile, unit, base, most)
            at = painted_at[image]
            unless at && at >= base
              at = @vram.take_tile(unit)
              @bytes << ("\x00" * (at - @bytes.bytesize)).b if at > @bytes.bytesize
              @bytes << tile
              painted_at[image] = at
            end
            @vram.tile_number(at, unit: unit, base: base, most: most) ||
              (raise LoweringError, too_far_message(name, at, unit, base, most))
          end

          # A map cell holds its tile number in ten bits, counted in the layer's own tile
          # size from wherever the layer starts counting — so it can name a run of 32K
          # stored the small way, 64K stored the big way, and each layer gets its own run.
          # Past that a tileset is not too big for the memory, it is too far for one map to
          # point across, and saying which is the difference between a fixable message and
          # a baffling one.
          def too_far_message(name, offset, unit, base, most)
            "background :#{name} counts its tiles from #{base} bytes into video memory and has one at " \
              "#{offset}, which is past the #{most * unit} bytes a map cell can reach across.#{mirrors_message} " \
              "Use fewer different tiles, or declare this background before the ones with the biggest tilesets."
          end

          # What the layer already got back from its mirrors, so the author does not go
          # looking for the saving the build made for them.
          def mirrors_message
            return "" unless @layer_mirrors.positive?

            " #{@layer_mirrors} of its tiles were another of its tiles mirrored, and those are already stored only once."
          end

          def align(value, to) = ((value + to - 1) / to) * to
        end
      end
    end
  end
end
