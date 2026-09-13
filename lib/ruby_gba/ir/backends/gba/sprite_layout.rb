# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # ONE ATTEMPT AT FITTING THE SPRITES' PICTURES INTO THE CONSOLE'S 32K.
        #
        # Every sprite either keeps all its pictures in sprite memory or keeps room for one
        # frame at a time (see PictureSet), and which sprites do which is settled by trying:
        # lay them all out, ask whether it fits, keep one more set of pictures to a frame,
        # try again. This is one of those attempts, and everything the next decision needs
        # to be made — and everything the report afterwards says — is on it.
        #
        # ALWAYS-THERE ART FIRST, then each scene's own over the same room.
        #
        # A sprite declared inside a scene is on screen only while that scene is the active
        # state — that is what a scene already means — so no two scenes' pictures are ever
        # wanted at once. Which means the budget a game has to fit is ONE SCENE'S, not the
        # whole game's, and a game with more art than the console's 32K still builds so long
        # as no single scene has. That is what lets a game with hundreds of rooms declare
        # each room's cast where it belongs.
        #
        # A scene's pictures are sent when that scene takes over rather than at boot, and
        # only when it is not already the one loaded — so staying in a scene costs one
        # compare a frame and changing scene costs a copy.
        class SpriteLayout
          # Where a sprite's frames go in the cartridge, kept as they are rather than packed
          # (see SpriteLayout#one_frame_placement).
          Blobs = Data.define(:emit, :keep_plain) do
            def plain(name, bytes)
              emit.data_blobs[name] = bytes
              keep_plain.call(name)
            end
          end

          # +pictures+ is every sprite's pictures by name, +one_frame+ the names kept to one
          # frame at a time this time round, and +blobs+ where a kept-to-one-frame sprite's
          # frames go in the cartridge. The block is given a sprite's pictures and where they
          # landed, and gives back the record the drawing reads.
          def initialize(emit:, nodes:, pictures:, one_frame:, blobs:, &record)
            @art = ObjectArt.new(emit)
            @pictures = pictures
            @one_frame = one_frame
            @blobs = blobs
            @record = record
            @sprites = {}      # name -> what the drawing reads
            @scene_art = {}    # scene -> the pictures it sends when it takes over
            @scene_bytes = {}  # scene -> what it needs, the always-there pictures included
            @repeats = 0       # bytes a piece did not cost because another piece already held them
            lay_out(nodes)
          end

          attr_reader :sprites, :scene_art, :repeats

          def fits?(capacity) = bytes <= capacity
          def bytes = @art.bytes
          def saved = @art.saved

          # The scene whose pictures, with the ones every screen shows, need the most sprite
          # memory — or nothing, for a game whose sprites all belong to every screen.
          def fullest_scene = @scene_bytes.max_by { |_scene, bytes| bytes }&.first

          private

          def lay_out(nodes)
            by_scene = nodes.group_by(&:scene)
            (by_scene[nil] || []).each { |node| place(node) }
            @art.seal_resident
            by_scene.each do |scene, in_scene|
              next if scene.nil?

              @art.begin_scene
              in_scene.each { |node| place(node) }
              @scene_bytes[scene] = @art.bytes_so_far
              @scene_art[scene] = @art.end_scene
            end
          end

          # A sprite's place in sprite memory: its pictures stored whole where they fit, or
          # room for one frame where it is kept to one at a time.
          def place(node)
            pictures = @pictures.fetch(node.name)
            @sprites[node.name] =
              if @one_frame.include?(node.name)
                @record.call(pictures, one_frame_placement(pictures))
              else
                @repeats += pictures.repeats
                blob, unit = @art.place(node.name, pictures.stored, narrow: pictures.place.narrow?)
                { starts: pictures.starts, alike: pictures.evenly_spaced?,
                  per_pose: pictures.evenly_spaced? ? pictures.stride : 0,
                  tiles: blob, tile_units: pictures.stored_bytes / 32, tile_index: unit }
                  .then { |placed| @record.call(pictures, placed) }
              end
          end

          # THE ROOM FOR ONE FRAME. Every pose is laid out the same way inside it, so the
          # table the drawing reads points at the room and never changes, and copying a frame
          # in is all that showing it takes. Every frame goes into the cartridge at the room's
          # stride, where the copy finds it, and stays as it is there — a frame is found by
          # where it starts, so the bytes must not be packed.
          def one_frame_placement(pictures)
            blob = :"__obj_frames_#{pictures.name}"
            @blobs.plain(blob, pictures.frames)
            units = pictures.frame_bytes / 32
            { starts: pictures.room_starts, alike: pictures.one_shape?, per_pose: 0,
              tiles: nil, tile_units: units,
              tile_index: @art.reserve(units, narrow: pictures.place.narrow?),
              frames: blob, frame_bytes: pictures.frame_bytes }
          end
        end
      end
    end
  end
end
