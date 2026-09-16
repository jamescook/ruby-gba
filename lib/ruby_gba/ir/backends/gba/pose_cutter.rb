# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # The picture sizes sprite hardware can draw, each mapped to the two shape/size
        # numbers that describe it. (The sizes fall out of how the hardware groups an
        # object's 8x8 tiles into a rectangle.) A picture that is NOT one of these is
        # drawn as several objects at once — see PoseCutter#pieces_of.
        OBJ_SIZES = {
          [8, 8] => [0, 0],  [16, 16] => [0, 1], [32, 32] => [0, 2], [64, 64] => [0, 3],
          [16, 8] => [1, 0], [32, 8] => [1, 1],  [32, 16] => [1, 2], [64, 32] => [1, 3],
          [8, 16] => [2, 0], [8, 32] => [2, 1],  [16, 32] => [2, 2], [32, 64] => [2, 3],
        }.freeze

        # The largest object the console has: not one of the twelve draws more than this
        # many pixels a side.
        OBJ_MAX_SIDE = 64

        # The largest picture the framework will cut up into objects. The ceiling is the
        # pose table's own: it says where each piece sits inside the picture as a whole
        # byte each way, so a bigger picture has corners it could not name.
        MAX_OBJECT_CANVAS = 256

        # The most objects one sprite is cut into. Cutting more finely drops more blank and
        # so costs less picture memory, but every piece spends one of the 128 places the
        # console draws from — and on a large sparse picture the saving alone would happily
        # take twenty of them.
        #
        # The COARSEST cover always fits under this, which is what makes it a preference
        # rather than a wall: the largest picture is MAX_OBJECT_CANVAS square and the
        # largest object OBJ_MAX_SIDE square, so a cover of those never comes to more.
        MAX_OBJECT_PIECES = (MAX_OBJECT_CANVAS / OBJ_MAX_SIDE)**2

        # HOW A SPRITE'S PICTURES ARE CUT INTO THE RECTANGLES THE CONSOLE DRAWS, and packed
        # into tiles the way it reads them. Nothing here knows about memory or about where a
        # sprite ends up: it is the art and the twelve shapes the hardware has.
        class PoseCutter
          include Cartridge::Constants

          def initialize(bitmaps)
            @bitmaps = bitmaps
          end

          # EVERYTHING ABOUT A SPRITE'S POSES THAT DOES NOT DEPEND ON MEMORY: which poses are
          # another pose mirrored, and the boxes each pose is drawn from. Worked out before
          # any sprite is given a place in the console's table, because a picture too big for
          # one object is drawn as SEVERAL and each of them takes a place of its own.
          #
          # A SPRITE THAT TURNS OR RESIZES IS NEITHER TRIMMED NOR MIRRORED, and that is
          # about being right rather than about being easy. The console spins an object
          # about the middle of its own box, so trimming the blank away would move the
          # pivot and the sprite would swing around a different point than the author drew
          # it to; and the two attribute bits that mirror an object are the ones that name
          # the rotation group once it is turning, so there are none left to mirror with.
          def cut(node, transformed:)
            width, height = size_of!(node.name, node.poses)
            guard_canvas!(node, width, height, transformed: transformed)
            # EACH POSE IS STORED AT ITS OWN SIZE, trimmed to what it actually draws
            # (see #pieces_of) rather than at the canvas they were all drawn on.
            boxes = node.poses.map do |image|
              transformed ? [[0, 0, width, height]] : pieces_of(@bitmaps.fetch(image))
            end
            mirrors = transformed ? Array.new(node.poses.length) : mirrors_of(node.poses)
            { width: width, height: height, boxes: boxes,
              mirrors: reflect_mirrored_poses(mirrors, boxes, width) }
          end

          # Pack a sprite's picture into tiles the way sprite hardware reads them: 8x8
          # tiles in reading order (left to right, top to bottom), each tile's 64 pixels
          # row by row, every pixel a number picking a color out of the table. A
          # see-through pixel becomes 0. Because we use 1D mapping, the tiles simply sit
          # one after another in memory.
          #
          # A NARROW sprite packs two pixels into every byte — the left one in the low
          # half, the right one in the high half, which is the order the console reads
          # them back in — so its picture is half the size for the same pixels. (In this
          # console's own words: 4bpp, low nibble first. A 4bpp OBJ tile is 32 bytes and an
          # 8bpp one 64, but OBJ tile NUMBERS count in 32s either way — which is why a wide
          # sprite has to start on an even one, see GBA#prepare_objects.)
          def encode(bmp, placement, box = nil)
            width = bmp.width
            height = bmp.height
            indices = placement.indices
            bytes = (+"").b
            # The part of the picture this pose is stored from — its whole self unless it
            # was trimmed to what it draws (see #pieces_of).
            box_x, box_y, box_w, box_h = box || [0, 0, width, height]
            (box_h / TILE_PX).times do |tile_row|
              (box_w / TILE_PX).times do |tile_col|
                TILE_PX.times do |row|
                  pending = nil
                  TILE_PX.times do |col|
                    y = box_y + (tile_row * TILE_PX) + row
                    x = box_x + (tile_col * TILE_PX) + col
                    # A piece of a cut-up picture can hang past the canvas's edge (see
                    # #grid_cells); what is out there draws nothing.
                    index = if x >= width || y >= height
                              0
                            else
                              i = (y * width) + x
                              bmp.drawn_at?(i) ? slot_of(bmp, i, indices, placement) : 0
                            end
                    next bytes << index.chr unless placement.narrow?

                    if pending.nil?
                      pending = index
                    else
                      bytes << (pending | (index << 4)).chr
                      pending = nil
                    end
                  end
                end
              end
            end
            bytes
          end

          # WHICH NUMBER ONE PIXEL IS STORED AS.
          #
          # A picture that got a BANK of sixteen reads its colors out of the author's own
          # list, so a place in that list IS the number to write — which is what keeps two
          # places holding the same color apart. A picture stored the big way reads the
          # whole shared table instead, where the same color is one entry however many
          # places the author's list gave it, so there is nothing to keep apart and the
          # color is looked up.
          def slot_of(bmp, index, indices, placement)
            place = placement.narrow? && bmp.place_at(index)
            place || indices.fetch(bmp.color_at(index))
          end

          # All of a sprite's poses share one size (they swap in place). Confirm that and
          # return it; a size mismatch is a build error rather than a garbled sprite.
          def size_of!(name, poses)
            sizes = poses.map do |image|
              bmp = @bitmaps.fetch(image) # presence already checked while building the palette
              [bmp.width, bmp.height]
            end
            return sizes.first if sizes.uniq.size == 1

            raise LoweringError,
                  "sprite #{name.inspect} has poses of different sizes " \
                  "(#{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}) — a sprite's poses must all be " \
                  "the same size"
          end

          private

          # THE PICTURE THE AUTHOR DREW HAS TO BE MADE OF WHOLE TILES, and small enough that
          # the pose table can say where each of its pieces sits. Everything between those
          # two the framework cuts up for itself, so this is the whole of what it refuses.
          # The message names the PICTURE rather than the sprite, since a sprite's own name
          # is the framework's and the author named the art.
          def guard_canvas!(node, width, height, transformed:)
            art = node.poses.first
            if width % TILE_PX != 0 || height % TILE_PX != 0
              raise LoweringError,
                    "A sprite in screen :tiled is built from #{TILE_PX}x#{TILE_PX} tiles. So its picture " \
                    "must be a multiple of #{TILE_PX} pixels each way. The picture :#{art} is " \
                    "#{width}x#{height}. To fix this, resize it."
            end
            if width > MAX_OBJECT_CANVAS || height > MAX_OBJECT_CANVAS
              raise LoweringError,
                    "A sprite in screen :tiled can be #{MAX_OBJECT_CANVAS} pixels each way at most. " \
                    "The picture :#{art} is #{width}x#{height}. To fix this, draw it smaller, or build " \
                    "this part of the picture from a background instead."
            end
            return if !transformed || OBJ_SIZES.key?([width, height])

            raise LoweringError,
                  "A sprite that turns or changes size must be one of these sizes: " \
                  "#{OBJ_SIZES.keys.map { |w, h| "#{w}x#{h}" }.join(', ')}. The picture :#{art} is " \
                  "#{width}x#{height}. A picture that size is drawn as several sprites at once. The console " \
                  "turns each sprite about its own middle, so the picture will come apart. To fix this, draw " \
                  "it at one of the sizes above, or do not turn or resize it."
          end

          # A POSE THAT IS ANOTHER ONE MIRRORED IS NOT STORED AT ALL: it is drawn from the
          # source's tiles, reversed, so its boxes are the source's reflected in the canvas.
          #
          # Unless one of them would land at a NEGATIVE offset, and then this pose keeps its
          # own pixels after all. That happens where a box is bigger than the picture it came
          # from — a 24x24 picture stored as one 32x32 object overhangs by eight, and its
          # reflection would have to be drawn eight pixels to the left of the canvas, which
          # the pose table has no way to say. Rare, and costs only the memory the sharing
          # would have saved.
          def reflect_mirrored_poses(mirrors, boxes, width)
            mirrors.each_with_index.map do |source, k|
              next nil if source.nil?

              reflected = boxes[source].map { |box| mirrored_box(box, width) }
              next nil if reflected.any? { |(x0, _y0, _w, _h)| x0.negative? }

              boxes[k] = reflected
              source
            end
          end

          # WHICH POSES ARE ANOTHER POSE MIRRORED, so they can be stored once.
          #
          # "Left is the right one, backwards" is close to universal in 2D games, and the
          # console draws an object reversed for nothing — so a character that faces two
          # ways need only keep the pixels once. An eight-frame walk drawn both ways comes
          # to 128 tiles rather than 256; a four-way character whose left mirrors its right,
          # 240 rather than 320.
          #
          # NOBODY HAS TO SAY SO. The sameness is judged on the pixels, so a game that drew
          # its left-facing art by hand gets this with nothing to change, exactly as two
          # sprites showing the same picture already share it (see ObjectArt). Saying it —
          # `mirror(:hero_right)` — is then a way to skip drawing the art, not a way to ask
          # for the saving.
          #
          # Returns the pose each pose mirrors, or nil for one stored in its own right. A
          # mirror always points at a STORED pose, never at another mirror, so there is
          # never a chain to follow.
          #
          # A pose that repeats an earlier one EXACTLY is not called a mirror, even though a
          # symmetric picture is its own mirror and would answer to the test below. Its
          # pieces already share the earlier pose's tiles (see SpritePictures), so calling it
          # a mirror would only add the bit that draws it backwards — three more instructions
          # a frame to reverse a picture that reads the same either way.
          def mirrors_of(poses)
            seen = {}     # the pixels of every pose stored so far
            reversed = {} # what a mirror of a stored pose would look like -> that pose
            poses.each_with_index.map do |image, k|
              bmp = @bitmaps.fetch(image)
              drawn = stored_as(bmp)
              next nil if seen.key?(drawn)
              next reversed[drawn] if reversed.key?(drawn)

              seen[drawn] = k
              reversed[stored_as(bmp.mirrored)] ||= k
              nil
            end
          end

          # WHAT TWO POSES HAVE TO MATCH IN to be stored once. The pixels, and — for art
          # given as places — the places too: two pictures can draw the same colors out of
          # different places of one list, and the console stores the places.
          def stored_as(bmp) = bmp.places ? [bmp.pixels, bmp.places] : bmp.pixels

          # Where a mirrored pose's box sits: the source's box reflected in the canvas it
          # was drawn on. Taken from the source rather than worked out from the mirrored
          # picture's own pixels because that is what the console will actually draw —
          # it reverses the source's box, so this is the window those tiles land in.
          def mirrored_box((x0, y0, w, h), width)
            [width - x0 - w, y0, w, h]
          end

          # WHAT ONE POSE DRAWS, as boxes the console can hold — one for a picture that is
          # already a size it has, SEVERAL for one that is not.
          #
          # The console's largest object is 64x64, and it draws only twelve rectangles. That
          # used to be the ceiling on a sprite: a boss, a vehicle, a title-screen character
          # had to be hand-assembled out of several sprite handles the game then moved in
          # step, which is real bookkeeping to ask of an author and easy to get subtly wrong.
          # Nothing about the hardware requires that, though — several objects standing
          # shoulder to shoulder look exactly like one big one — so the framework cuts the
          # picture up and moves the pieces itself, and the author writes one sprite.
          #
          # The cut also pays for itself in memory, because a piece that draws NOTHING is not
          # stored at all. A character is a ragged shape in a rectangular canvas, so the
          # corners of that canvas are usually empty — and an object reads a contiguous run
          # of tiles, so a single big box has to keep every blank one.
          #
          # A PICTURE THE CONSOLE CAN ALREADY DRAW IS LEFT ALONE, and that is a promise
          # rather than a shortcut. Cutting one of those up would sometimes pay in memory,
          # but a pose that came out as several pieces puts the WHOLE sprite on the per-pose
          # word — so one sparse pose could quietly make every other pose dearer to draw.
          # Measured on every example in the repo, letting the search have them changed
          # nothing at all, so the promise costs nothing to keep.
          def pieces_of(bmp)
            return [pose_box(bmp)] if OBJ_SIZES.key?([bmp.width, bmp.height])

            left, top, right, bottom = drawn_extent(bmp)
            return [[0, 0, *OBJ_SIZES.keys.min_by { |w, h| w * h }]] if left.nil?

            x0 = (left / TILE_PX) * TILE_PX
            y0 = (top / TILE_PX) * TILE_PX
            best_grid(bmp, x0, y0, right - x0 + 1, bottom - y0 + 1)
          end

          # The cheapest cover: each of the twelve sizes tried as the cell, laid over what the
          # pose draws, with the cells that draw nothing dropped — and the winner judged on
          # its tiles PLUS what its objects are worth (see TILES_PER_OBJECT), so a finer cut
          # is taken only when the blank it drops pays for the places it spends.
          #
          # Trying all twelve rather than reaching for the biggest is what makes the memory
          # come out right: 64x64 cells over a 96x96 picture is four objects and 256 tiles,
          # where 32x32 cells is nine and 144 — and fewer still once the empty ones go.
          def best_grid(bmp, x0, y0, w, h)
            covers = OBJ_SIZES.keys.map do |cw, ch|
              cells = grid_cells(bmp, x0, y0, w, h, cw, ch)
              [cells.size * (cw / TILE_PX) * (ch / TILE_PX), cells.size, cells]
            end
            # A cover of the coarsest cells is always under the ceiling (see
            # MAX_OBJECT_PIECES), so there is always something left to choose from.
            covers.reject { |_tiles, count, _cells| count > MAX_OBJECT_PIECES }
                  .min_by { |tiles, count, _cells| [tiles + (count * TILES_PER_OBJECT), count] }
                  .last
          end

          # What one of the console's 128 places is worth, in tiles, and so how fine a cut is
          # worth making. The console holds about a thousand tiles stored the small way and
          # draws 128 objects at once, so a place and eight tiles are about the same share of
          # what there is. Without a number here the search spends places freely: a vehicle
          # came out as twelve objects to save a kilobyte, which is a bad trade twice over,
          # since every piece also costs its own writes into the sprite table each frame.
          TILES_PER_OBJECT = 8

          # The cells of one grid that draw something. The grid starts at the corner of what
          # the pose draws, and a cell that would hang past the far edge is PULLED BACK onto
          # the canvas — so two cells can overlap, which costs nothing to look at, since both
          # hold the picture's own pixels there.
          #
          # A cell BIGGER than the whole canvas needs no special case: every one of them is
          # pulled back to the corner, so they all land in the same place and the grid
          # collapses to the single object that covers the picture. That is how a 24x24
          # picture — a size the console does not have — comes out as one 32x32 object.
          def grid_cells(bmp, x0, y0, w, h, cw, ch)
            cells = []
            (0...h).step(ch) do |dy|
              cy = [y0 + dy, [bmp.height - ch, 0].max].min
              (0...w).step(cw) do |dx|
                cx = [x0 + dx, [bmp.width - cw, 0].max].min
                cells << [cx, cy, cw, ch] if draws_anything?(bmp, cx, cy, cw, ch)
              end
            end
            cells.uniq # pulling two cells back can land them in the same place
          end

          # Does any pixel of this part of the picture draw anything?
          def draws_anything?(bmp, x0, y0, w, h)
            (y0...[y0 + h, bmp.height].min).any? do |y|
              (x0...[x0 + w, bmp.width].min).any? { |x| bmp.drawn_at?((y * bmp.width) + x) }
            end
          end

          # WHAT ONE POSE ACTUALLY DRAWS, as a box the console can hold: [x0, y0, w, h],
          # where the corner is on a tile boundary and the size is one of the twelve the
          # hardware has.
          #
          # WHY THIS IS WORTH DOING. Every pose of a sprite is drawn on one canvas, big
          # enough for the widest frame — a sword swing, a jump — and most frames use a
          # fraction of it. Stored at the canvas's size, the rest is blank that still costs
          # sprite memory, because an object reads a CONTIGUOUS run of tiles and cannot
          # share the blank ones the way a background shares a repeated tile. Measured on a
          # walk cycle drawn 64x64 whose character covers 24x32, that is four times the
          # memory the art contains.
          #
          # The offset comes back with it because the picture must not MOVE: the character's
          # origin is the canvas's corner, which is where the author put the sprite, so a
          # pose trimmed by (x0, y0) is drawn (x0, y0) further along and lands exactly where
          # it did. Corner-aligned instead, a character jitters around its own feet as the
          # cycle plays.
          def pose_box(bmp)
            left, top, right, bottom = drawn_extent(bmp)
            return [0, 0, *OBJ_SIZES.keys.min_by { |w, h| w * h }] if left.nil?

            # Out to whole tiles, since a pose is stored as tiles and a partial one cannot
            # be addressed.
            x0 = (left / TILE_PX) * TILE_PX
            y0 = (top / TILE_PX) * TILE_PX
            w, h = smallest_size(right - x0 + 1, bottom - y0 + 1)
            # A box that would hang off the canvas is pulled back onto it, so the tiles it
            # reads are all real.
            [[x0, bmp.width - w].min.clamp(0, bmp.width), [y0, bmp.height - h].min.clamp(0, bmp.height), w, h]
          end

          # The first and last row and column of +bmp+ that draw anything, or nils for a
          # pose that is see-through all over.
          def drawn_extent(bmp)
            left = top = right = bottom = nil
            bmp.height.times do |y|
              bmp.width.times do |x|
                next unless bmp.drawn_at?((y * bmp.width) + x)

                left = x if left.nil? || x < left
                right = x if right.nil? || x > right
                top = y if top.nil?
                bottom = y
              end
            end
            [left, top, right, bottom]
          end

          # The smallest size the hardware has that holds +w+ by +h+, or the largest if
          # nothing does (the caller has already been told a picture that big is refused).
          def smallest_size(w, h)
            fits = OBJ_SIZES.keys.select { |ow, oh| ow >= w && oh >= h }
            (fits.min_by { |ow, oh| ow * oh } || OBJ_SIZES.keys.max_by { |ow, oh| ow * oh })
          end
        end
      end
    end
  end
end
