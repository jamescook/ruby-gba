# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # WHICH BOXES A SPRITE'S PICTURES ARE DRAWN AS, by a display that draws a sprite as
      # one or more objects of a few fixed sizes. It is the art and those sizes, and
      # nothing about where anything ends up in a cartridge.
      #
      # Both backends read it. The one that builds a cartridge needs the boxes to store
      # each pose and to place it. The interpreter needs them for one thing only, a
      # sprite shown in blocks, because each object is put into blocks by itself (see
      # Reference::SpriteBlocks) — and it is asked here rather than worked out a second
      # time there, so the two cannot come to different cuts.
      class SpriteCut
        # An object is built from tiles this many pixels each way.
        TILE = 8

        # The picture sizes sprite hardware can draw, each mapped to the two shape/size
        # numbers that describe it. (The sizes fall out of how the hardware groups an
        # object's 8x8 tiles into a rectangle.) A picture that is NOT one of these is
        # drawn as several objects at once — see SpriteCut#pieces_of.
        OBJ_SIZES = Ractor.make_shareable({
          [8, 8] => [0, 0],  [16, 16] => [0, 1], [32, 32] => [0, 2], [64, 64] => [0, 3],
          [16, 8] => [1, 0], [32, 8] => [1, 1],  [32, 16] => [1, 2], [64, 32] => [1, 3],
          [8, 16] => [2, 0], [8, 32] => [2, 1],  [16, 32] => [2, 2], [32, 64] => [2, 3],
        })

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

        # A pose that is another pose turned: the pose it is drawn from, and whether the
        # console reverses it left to right (+across+), top to bottom (+down+), or both.
        Mirror = Data.define(:source, :across, :down)

        def initialize(bitmaps)
          @bitmaps = bitmaps
        end

        # The boxes each of +poses+ is drawn from, and which poses are another pose
        # mirrored: `{ boxes:, mirrors: }`, a list for each pose. A box is
        # [left, top, width, height] inside the canvas, +width+ by +height+, that every
        # pose was drawn on, and a pose's boxes are in the order a display draws them,
        # the one in front first.
        #
        # +whole+ keeps each pose as one box, the whole canvas, with nothing trimmed and
        # nothing mirrored — for a sprite that turns or resizes, which is turned about
        # the middle of its box, and for a picture that is painted while the game runs.
        def cut(poses, width:, height:, whole:)
          boxes = poses.map do |image|
            whole ? [[0, 0, width, height]] : pieces_of(@bitmaps.fetch(image))
          end
          mirrors = whole ? Array.new(poses.length) : mirrors_of(poses)
          { boxes: boxes, mirrors: reflect_mirrored_poses(mirrors, boxes, width, height) }
        end

        private

        # A POSE THAT IS ANOTHER ONE MIRRORED IS NOT STORED AT ALL: it is drawn from the
        # source's tiles, reversed, so its boxes are the source's reflected in the canvas.
        #
        # Unless one of them would land at a NEGATIVE offset, and then this pose keeps its
        # own pixels after all. That happens where a box is bigger than the picture it came
        # from — a 24x24 picture stored as one 32x32 object overhangs by eight, and its
        # reflection would have to be drawn eight pixels to the left of the canvas, which
        # the pose table has no way to say. Rare, and costs only the memory the sharing
        # would have saved.
        def reflect_mirrored_poses(mirrors, boxes, width, height)
          mirrors.each_with_index.map do |mirror, k|
            next nil if mirror.nil?

            reflected = boxes[mirror.source].map { |box| mirrored_box(box, mirror, width, height) }
            next nil if reflected.any? { |(x0, y0, _w, _h)| x0.negative? || y0.negative? }

            boxes[k] = reflected
            mirror
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
        # Returns, for each pose, the Mirror it is of another, or nil for one stored in its own
        # right. A mirror always points at a STORED pose, never at another mirror, so there is
        # never a chain to follow.
        #
        # A pose UPSIDE DOWN is the same saving the other way, and the console turns an object
        # top to bottom for nothing as well — a reflection, a stalactite from a stalagmite, an
        # arrow pointing either way. So is a pose turned both ways. Left to right is looked for
        # first, since it is the common one. These are looked for on every sprite, not only one
        # that said `upside_down`: the look is three hashes of a pose where it was one, at build
        # time, and a sprite moves onto the per-pose word only where a turned pose was found —
        # which is where it saves the memory of a whole pose.
        #
        # A pose that repeats an earlier one EXACTLY is not called a mirror, even though a
        # symmetric picture is its own mirror and would answer to the test below. Its
        # pieces already share the earlier pose's tiles (see SpritePictures), so calling it
        # a mirror would only add the bit that draws it backwards — three more instructions
        # a frame to reverse a picture that reads the same either way.
        def mirrors_of(poses)
          seen = {}   # the pixels of every pose stored so far
          turned = {} # what a stored pose would look like turned -> the Mirror that turns it
          poses.each_with_index.map do |image, k|
            bmp = @bitmaps.fetch(image)
            drawn = pose_identity(bmp)
            next nil if seen.key?(drawn)
            next turned[drawn] if turned.key?(drawn)

            seen[drawn] = k
            across, down, both = turned_identities(bmp)
            turned[across] ||= Mirror.new(source: k, across: true, down: false)
            turned[down] ||= Mirror.new(source: k, across: false, down: true)
            turned[both] ||= Mirror.new(source: k, across: true, down: true)
            nil
          end
        end

        # What +bmp+ looks like mirrored, upside down, and both, as #pose_identity says it.
        def turned_identities(bmp)
          Remembered.fetch(:turned_identities, bmp) do
            [bmp.mirrored, bmp.upside_down, bmp.mirrored.upside_down].map { |turned| pose_identity(turned) }
          end
        end

        # WHAT TWO POSES HAVE TO MATCH IN to be stored once. The pixels, and — for art
        # given as places — the places too: two pictures can draw the same colors out of
        # different places of one list, and the console stores the places.
        def pose_identity(bmp) = bmp.places ? [bmp.pixels, bmp.places] : bmp.pixels

        # Where a mirrored pose's box sits: the source's box reflected in the canvas it
        # was drawn on. Taken from the source rather than worked out from the mirrored
        # picture's own pixels because that is what the console will actually draw —
        # it reverses the source's box, so this is the window those tiles land in.
        def mirrored_box((x0, y0, w, h), mirror, width, height)
          [mirror.across ? width - x0 - w : x0, mirror.down ? height - y0 - h : y0, w, h]
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
        #
        # Every pixel is read to find this, so it is remembered for the next build that holds
        # the same picture (see IR::Remembered).
        def pieces_of(bmp)
          Remembered.fetch(:sprite_pieces, bmp) do
            next [pose_box(bmp)] if OBJ_SIZES.key?([bmp.width, bmp.height])

            left, top, right, bottom = drawn_extent(bmp)
            next [[0, 0, *OBJ_SIZES.keys.min_by { |w, h| w * h }]] if left.nil?

            x0 = (left / TILE) * TILE
            y0 = (top / TILE) * TILE
            best_grid(bmp, x0, y0, right - x0 + 1, bottom - y0 + 1)
          end
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
            [cells.size * (cw / TILE) * (ch / TILE), cells.size, cells]
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
          x0 = (left / TILE) * TILE
          y0 = (top / TILE) * TILE
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
