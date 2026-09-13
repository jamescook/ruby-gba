# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # ONE SPRITE'S PICTURES, as the console will hold them — worked out once per build, since
        # nothing about them depends on where in sprite memory they land or on which sprites end
        # up kept to one frame at a time.
        #
        # +encoded+ is each pose's pieces as tile bytes, or nil for a pose that is another one
        # mirrored (it is drawn from that pose's tiles, reversed). +boxes+ is each pose's pieces
        # as boxes in its canvas, the short poses filled out with blank pieces so every pose has
        # as many as the most any has. +stored+ is what the sprite keeps in sprite memory when it
        # keeps every frame — each distinct piece once — and +starts+ where each pose's pieces
        # begin inside that; +repeats+ is the bytes those repeated pieces did not cost. +place+
        # is the colour storage the sprite draws from, and +animates+ whether the game picks
        # among more than one pose while it runs.
        SpritePictures = Data.define(:node, :place, :boxes, :mirrors, :encoded, :stored, :starts,
                                     :repeats, :animates) do
          def name = node.name
          def scene = node.scene
          def animates? = animates
          def pieces = boxes.first.size
          def stored_bytes = stored.bytesize

          # EVERY POSE DRAWN OUT OF ONE BOX, and none of them another reversed. Then the sprite's
          # own entry can carry that one size and the draw needs no table of poses.
          def one_shape? = pieces == 1 && boxes.map(&:first).uniq.size == 1 && mirrors.none?

          # DOES ONE POSE'S TILES FOLLOW THE LAST'S, ALL THE WAY DOWN? That is what the plain
          # draw assumes: it multiplies the pose the game is showing by a fixed stride, so
          # the poses have to sit an even distance apart in the order they were declared. A
          # pose that REPEATS an earlier one is stored once and points back at it, which
          # usually breaks the run — so such a sprite carries the pose table instead, where
          # each pose says where its own tiles are. Usually, and not always: a cycle whose
          # frames are ALL the same picture shares one run, which is an even distance of
          # nothing, and it keeps the plain draw.
          #
          # THAT TRADE IS THE ONE DECISION HERE, and it goes this way because the two sides
          # are not the same kind of thing. Falling to the table measured 12 instructions a
          # frame on a four-pose sprite; what it buys is at least one whole pose of picture
          # memory, and picture memory is a WALL — a game that runs out does not build at
          # all, where a frame that is 12 instructions longer is a frame nobody can see.
          # Keeping the plain draw and looking the pose up in a table of its own would cost
          # about two instructions instead of twelve, and it was not worth a third way
          # through the hottest code in the frame to save ten.
          def evenly_spaced? = one_shape? && starts.each_with_index.all? { |at, k| at.first == k * stride }

          # The stride from one pose's tiles to the next, read off where the second one landed
          # rather than divided out of the total: a cycle whose frames are all the SAME picture
          # shares one run between them, and its stride is then 0, which is the truth.
          def stride = starts.length > 1 ? starts[1].first : 0

          # THE ROOM ONE FRAME TAKES, piece by piece, for a sprite kept to one frame at a time:
          # the most any pose needs for that piece, and a blank tile where a pose has none.
          def room
            blank = place.narrow? ? 32 : 64
            (0...pieces).map { |piece| encoded.compact.map { |list| list[piece]&.bytesize || blank }.max }
          end

          def frame_bytes = room.sum

          # Where each piece sits in that room, in the 32-byte units a tile number counts in —
          # the same for every pose, which is what lets the room be filled by a copy.
          def room_starts
            at = room.each_index.map { |piece| room.first(piece).sum / 32 }
            node.poses.map { at.dup }
          end

          # EVERY FRAME, laid out the way the room is and back to back, for the cartridge: a
          # mirrored pose holds the pictures of the pose it mirrors, and a piece a pose does not
          # have holds nothing, which the console draws as nothing.
          def frames
            node.poses.each_index.map do |k|
              list = encoded[mirrors[k] || k]
              room.each_with_index.map { |bytes, piece| (list[piece] || "".b).ljust(bytes, "\0".b) }.join
            end.join.b
          end
        end

        # A SET OF PICTURES AND EVERY SPRITE SHOWING IT. Two sprites showing the same pictures
        # store them once (see ObjectArt) — every slot of a pool does — so the set, not the
        # sprite, is what can give sprite memory back.
        PictureSet = Data.define(:sprites) do
          def names = sprites.map(&:name)

          # Every sprite showing it picks among more than one pose while the game runs. One that
          # always shows the same picture has no frames to give up, and it keeps the set whole.
          def can_keep_to_one_frame? = sprites.all?(&:animates?)

          # What keeping every sprite showing it to one frame gives back where memory is over:
          # the pictures every screen shows, and +scene+'s. The set is stored once there however
          # many of them show it, and each costs a frame's room instead.
          def gives_back(scene)
            counted = sprites.count { |sprite| [nil, scene].include?(sprite.scene) }
            return 0 if counted.zero?

            sprites.first.stored_bytes - (sprites.first.frame_bytes * counted)
          end
        end
      end
    end
  end
end
