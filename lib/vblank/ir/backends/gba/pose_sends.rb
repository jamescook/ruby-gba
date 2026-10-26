# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A POOL'S POSES GO INTO SPRITE MEMORY ONE AT A TIME, the first time one of its things
        # shows each, rather than all together as its scene takes over.
        #
        # A scene's sprite pictures are copied in when it arrives, and the processor waits for
        # the copy. For a sprite on screen from the start that wait is worth it. For a pool it is
        # every pose any of its things could ever show — a pot's shards, an explosion, a spark —
        # and most of them are not on screen when the player walks into the room, or for a long
        # time after. Copying them anyway can cost a whole frame: a scene whose arrival already ran
        # close to the end of its frame was pushed a few lines past it by a pot's shards nobody
        # was looking at, and a pass that ends after the gap between pictures has begun waits for
        # the next one. The console's own games do it this way round: an effect's pictures are
        # loaded when one is spawned.
        #
        # So each pose of such a pool has a byte in memory saying whether it has been sent since
        # its scene took over. Drawing a thing of the pool asks its pose's byte, and the first
        # time it is nought, copies that pose's tiles out of the cartridge and sets it. The copy
        # is in the gap between frames, beside the sprite's own row of the table, so the picture
        # and the row pointing at it arrive together. Every byte goes back to nought when the
        # scene takes over again, since another scene's pictures went into the same memory.
        #
        # ONE TILE IS PUT IN AS THE SCENE ARRIVES ALL THE SAME. A pose cut into fewer of the
        # console's pieces than the pool's biggest is filled out with blank pieces (every thing of
        # a pool takes the same number of places in the sprite table), and those all draw one
        # blank tile kept after the last pose. No pose's own run of tiles reaches it, so it is
        # cleared to nothing as the scene arrives, which is a handful of stores.
        #
        # What it costs is a load and a compare for each live thing on each frame, and the copy
        # once per pose per visit, a pose's worth rather than the pool's.
        #
        # WHICH POOLS: one declared in a scene, whose pictures are its own. A pool showing the
        # same pictures as some other sprite shares them with it, and that sprite may be on screen
        # the moment the scene arrives, so those pictures still go in then; and a pool kept to one
        # frame at a time already copies only what it shows.
        class PoseSends
          # One pool whose poses are sent as they are first shown. +blob+ is all its pictures in
          # the cartridge, which go from tile +tile_index+ on; +table+ is a word a pose, where that
          # pose's tiles start in the blob in the low half and how many there are in the high
          # half, both in the 32-byte units sprite memory counts in; +count+ is how many poses;
          # +scene+ is the scene that owns the pool, and +sprites+ the names of its sprites.
          # +blank_at+ is where the blank tile the filler pieces draw sits in the blob, and
          # +blank_bytes+ how big it is, or both nil for a pool whose poses need no filling out.
          Pool = Data.define(:blob, :tile_index, :table, :count, :scene, :sprites, :blank_at, :blank_bytes)

          # +objects+ is every sprite's record by name and +pictures+ their pictures. +blobs+ is the
          # cartridge's data: each pool's table of where its poses are is added to it.
          def initialize(objects:, pictures:, blobs:)
            @objects = objects
            @pictures = pictures
            @blobs = blobs
          end

          # Every pool whose poses are sent as they are first shown, by the blob of its pictures.
          def pools
            showing_one_set.filter_map do |names|
              owner = names.find { |name| @objects.fetch(name).tiles }
              pool_for(owner, names) if owner && one_pool?(names)
            end.to_h { |pool| [pool.blob, pool] }
          end

          private

          # The sprites of one scene that show one set of pictures, group by group.
          def showing_one_set
            # A sprite whose poses are copied in by their groups has its pictures brought in that
            # way instead.
            @objects.select { |name, obj| obj.scene && obj.frames.nil? && !@pictures.fetch(name).grouped? }
                    .group_by { |_name, obj| [obj.scene, obj.tile_index] }
                    .values.map { |pairs| pairs.map(&:first) }
          end

          # Every one of them a thing of the same pool: the build names a pool's sprites as parts of
          # the pool, and reading the name back says which.
          def one_pool?(names)
            pools = names.map do |name|
              kind, parts = Messages::MadeNames.read(name)
              parts[:pool] if kind == :pool_part
            end
            !pools.include?(nil) && pools.uniq.size == 1
          end

          # Where each pose's tiles sit in the blob: from the first tile any of its pieces starts
          # at to the end of the last. A pose that shares a piece stored earlier in the blob
          # copies the stretch between as well, which is the right bytes for that stretch too.
          # A filler piece has no pictures of its own and is left out of the run (see the class
          # comment for the tile it draws).
          def pool_for(owner, names)
            obj = @objects.fetch(owner)
            pictures = @pictures.fetch(owner)
            fillers = []
            words = pictures.starts.each_with_index.map do |starts, pose|
              drawn = pictures.encoded[pictures.mirrors[pose]&.source || pose]
              spans = starts.each_with_index.filter_map do |at, piece|
                bytes = drawn[piece]
                fillers << at unless bytes
                [at, at + (bytes.bytesize / 32)] if bytes
              end
              first = spans.map(&:first).min || 0
              last = spans.map(&:last).max || 0
              first | ((last - first) << 16)
            end
            table = :"__pose_sends_#{owner}"
            @blobs[table] = words.pack("V*")
            Pool.new(blob: obj.tiles, tile_index: obj.tile_index, table: table, count: words.length, scene: obj.scene,
                     sprites: names, blank_at: fillers.first,
                     blank_bytes: fillers.empty? ? nil : (pictures.place.narrow? ? 32 : 64))
          end
        end
      end
    end
  end
end
