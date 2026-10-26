# frozen_string_literal: true

module VBlank
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
          Blobs = Data.define(:data_blobs, :keep_plain) do
            def store_unpacked(name, bytes)
              data_blobs[name] = bytes
              keep_plain.call(name)
            end
          end

          # ROOMS SHARED BY THE SPRITES OF ONE SCENE THAT SHOW ONE SET OF PICTURES, kept to one
          # frame at a time. There is a room for each of those sprites, +count+ of them, each
          # +units+ long, from the unit +first+ on; every pose is in the cartridge at +frames+, laid
          # out the way a room is, +frame_bytes+ apart.
          #
          # A sprite does not own a room. It takes one as it is drawn: the room already holding the
          # pose it shows, if one is, and a room nobody is drawing from otherwise, copying its pose
          # in. So two sprites showing the same pose draw from one room and the pose is copied once,
          # and a pose stays in a room nobody uses until another pose needs the room.
          #
          # THERE IS ALWAYS A ROOM TO TAKE. A sprite lets go of its own room before it looks, which
          # leaves the others at most one room each, and there is one more room than that. So the
          # game can never run out, which is the one thing a shared heap of sprite memory cannot
          # promise — there, a thing that does not fit is not drawn.
          #
          # THE RECORD OF THE ROOMS, which the running game keeps (see
          # SpriteDrawing#emit_shared_room_routines): two words for each room, which pose it holds
          # and how many sprites draw from it, and then a word for each sprite, which room it
          # holds. Where it is kept is the lowering's to decide; how it is laid out is said here
          # once, for the code that sizes it and the code that reads it.
          SharedRooms = Data.define(:first, :units, :count, :frames, :frame_bytes) do
            def table_bytes = count * (self.class::ROOM_WORDS_BYTES + self.class::HELD_WORD_BYTES)

            # Where in the record room +room+'s two words start, and the asking sprite's word.
            def room_at(room) = room * self.class::ROOM_WORDS_BYTES
            def held_at(member) = (count * self.class::ROOM_WORDS_BYTES) + (member * self.class::HELD_WORD_BYTES)
          end

          class SharedRooms
            ROOM_WORDS_BYTES = 8 # a room's two words...
            ROOM_WORDS_SHIFT = 3 # ...so a room's number shifted this far is where they start
            USERS_AT = 4         # how many sprites draw from it, the second of them
            HELD_WORD_BYTES = 4  # a sprite's word...
            HELD_WORD_SHIFT = 2  # ...so a sprite's number shifted this far is where it is
          end

          # +pictures+ is every sprite's pictures by name, +one_frame+ the names kept to one
          # frame at a time this time round, and +blobs+ where a kept-to-one-frame sprite's
          # frames go in the cartridge. The block is given a sprite's pictures and where they
          # landed, and gives back the record the drawing reads.
          #
          # +painted+ is each sprite showing a picture the game paints from a list, by name, with
          # that picture's name. Such a sprite gets a room of its own the list is copied into,
          # and every sprite showing the same painted picture shares it.
          #
          # +grouped+ is the game's sets of picture groups (see GroupedPictures). Each set's room
          # is kept on the screen it belongs to, ahead of that screen's sprites, and a grouped
          # pose is drawn from its place there.
          def initialize(nodes:, pictures:, one_frame:, blobs:, painted: {}, grouped: nil, &record)
            @art = ObjectArt.new(blobs.data_blobs)
            @pictures = pictures
            @grouped = grouped
            @group_bases = {} # a set of picture groups -> the unit its room starts at
            @painted = painted
            @painted_rooms = {} # painted picture -> the unit its room starts at
            @one_frame = one_frame
            @blobs = blobs
            @record = record
            @sprites = {}      # name -> what the drawing reads
            @scene_art = {}    # scene -> the pictures it sends when it takes over
            @scene_bytes = {}  # scene -> what it needs, the always-there pictures included
            @repeats = 0       # bytes a piece did not cost because another piece already held them
            @shared_rooms = [] # every set of rooms shared by the sprites of one scene
            @rooms_bytes = {}  # scene, or nil for what every screen shows -> the bytes of those rooms on it
            @sharing = {}      # while one screen is laid out: a sprite sharing rooms -> every sprite it shares them with
            @rooms_of = {}     # ...and those sprites -> the rooms they share, once the first of them is placed
            lay_out(nodes)
          end

          attr_reader :sprites, :scene_art, :repeats, :shared_rooms, :group_bases

          def fits?(capacity) = bytes <= capacity
          def bytes = @art.bytes
          def saved = @art.saved

          # How many tiles the pictures every screen shows take, from the first: each scene's own
          # start after them.
          def resident_tiles = @art.resident_units

          # The scene whose pictures, with the ones every screen shows, need the most sprite
          # memory — or nothing, for a game whose sprites all belong to every screen.
          def fullest_scene = @scene_bytes.max_by { |_scene, bytes| bytes }&.first

          # Each screen's sprite memory, and how much of it is shared rooms, as [bytes, rooms]: each
          # scene's with what every screen shows, or, in a game with no scenes, what every screen
          # shows under nil.
          def screens
            everywhere = @rooms_bytes.fetch(nil, 0)
            return { nil => [@art.bytes, everywhere] } if @scene_bytes.empty?

            @scene_bytes.to_h { |scene, bytes| [scene, [bytes, everywhere + @rooms_bytes.fetch(scene, 0)]] }
          end

          private

          # A painted picture's room is kept per screen, like everything else here: the room it
          # had in one scene is some other picture's in the next, so a scene showing it again
          # gets a room of its own (and the copy is told where, see ScreenLayout::PaintedRun).
          def lay_out(nodes)
            by_scene = nodes.group_by(&:scene)
            reserve_group_rooms(nil)
            place_screen(by_scene[nil] || [])
            @art.finish_resident_art
            resident_rooms = @painted_rooms.dup
            by_scene.each do |scene, in_scene|
              next if scene.nil?

              @art.begin_scene
              @painted_rooms = resident_rooms.dup
              reserve_group_rooms(scene)
              place_screen(in_scene)
              @scene_bytes[scene] = @art.bytes_so_far
              @scene_art[scene] = @art.end_scene
            end
          end

          # One screen's sprites: what every screen shows, or one scene's. The sprites of it kept
          # to one frame that show the same poses share their rooms, when there are two or more of
          # them; one alone keeps a room of its own, as it always did.
          #
          # THE SAME POSES, IN THE SAME ORDER, and not merely the same pictures. A room is found by
          # the number of the pose it holds, so two sprites share rooms only when every pose number
          # means the same picture to both: the same pictures in another order are stored alike,
          # and a room holding one's pose 1 would draw as the other's pose 1. Every pose laid out
          # the way a room is, back to back, says exactly that.
          def place_screen(nodes)
            @screen = nodes.first&.scene
            @sharing = nodes.select { |node| @one_frame.include?(node.name) }
                            .group_by { |node| @pictures.fetch(node.name).frames }
                            .values.select { |alike| alike.size > 1 }
                            .flat_map { |alike| alike.map(&:name).then { |names| names.map { |name| [name, names] } } }
                            .to_h
            @rooms_of = {}
            nodes.each { |node| place(node) }
          end

          # A sprite's place in sprite memory: its pictures stored whole where they fit, or
          # room for one frame where it is kept to one at a time.
          def place(node)
            pictures = @pictures.fetch(node.name)
            @sprites[node.name] =
              if (sharing = @sharing[node.name])
                @record.call(pictures, shared_room_placement(pictures, sharing))
              elsif @one_frame.include?(node.name)
                @record.call(pictures, one_frame_placement(pictures))
              elsif (picture = @painted[node.name])
                @record.call(pictures, painted_placement(pictures, picture))
              elsif pictures.grouped?
                @record.call(pictures, grouped_placement(pictures))
              else
                @repeats += pictures.repeats
                blob, unit = @art.place(node.name, pictures.stored, narrow: pictures.place.narrow?)
                { starts: pictures.starts, alike: pictures.evenly_spaced?,
                  per_pose: pictures.evenly_spaced? ? pictures.stride : 0,
                  tiles: blob, tile_units: pictures.stored_bytes / 32, tile_index: unit }
                  .then { |placed| @record.call(pictures, placed) }
              end
          end

          # THE ROOM OF EACH SET OF PICTURE GROUPS THIS SCREEN OWNS, before any of its sprites: room
          # for nothing is kept for nothing.
          def reserve_group_rooms(scene)
            @grouped&.rooms_on(scene).each do |name, units|
              @group_bases[name] = @art.reserve(units, narrow: false) if units.positive?
            end
          end

          # A SPRITE SOME OF WHOSE POSES ARE COPIED IN BY THEIR GROUPS. Its other poses are kept
          # the ordinary way, and a grouped pose's pieces point at the place its set gave it, so
          # the poses are not an even stride apart and the sprite reads a table of them. Every
          # number in that table counts from the sprite's own first tile, so a grouped piece is
          # that far back from its place.
          def grouped_placement(pictures)
            @repeats += pictures.repeats
            blob, unit = pictures.stored.empty? ? [nil, 0] : @art.place(pictures.name, pictures.stored, narrow: pictures.place.narrow?)
            starts = pictures.starts.each_with_index.map do |list, k|
              pose = pictures.grouped[k]
              next list unless pose

              along = @group_bases.fetch(pose.set) + @grouped.offset(pose.set, pose.bytes) - unit
              list.each_with_index.map { |at, piece| piece < pose.pieces ? at + along : at }
            end
            { starts: starts, alike: false, per_pose: 0, tiles: blob, tile_units: pictures.stored_bytes / 32,
              tile_index: unit }
          end

          # THE ROOM A PAINTED PICTURE IS COPIED INTO, out of the game's list rather than the
          # cartridge — so there is nothing to store, only room to keep, and it is never shared
          # with a picture that merely looks the same, since the game changes it.
          def painted_placement(pictures, picture)
            units = pictures.stored_bytes / 32
            unit = (@painted_rooms[picture] ||= @art.reserve(units, narrow: pictures.place.narrow?))
            { starts: pictures.starts, alike: true, per_pose: 0, tiles: nil, tile_units: units, tile_index: unit }
          end

          # THE ROOM FOR ONE FRAME. Every pose is laid out the same way inside it, so the
          # table the drawing reads points at the room and never changes, and copying a frame
          # in is all that showing it takes. Every frame goes into the cartridge at the room's
          # stride, where the copy finds it, and stays as it is there — a frame is found by
          # where it starts, so the bytes must not be packed.
          def one_frame_placement(pictures)
            blob = :"__obj_frames_#{pictures.name}"
            @blobs.store_unpacked(blob, pictures.frames)
            units = pictures.frame_bytes / 32
            { starts: pictures.room_starts, alike: pictures.one_shape?, per_pose: 0,
              tiles: nil, tile_units: units,
              tile_index: @art.reserve(units, narrow: pictures.place.narrow?),
              frames: blob, frame_bytes: pictures.frame_bytes }
          end

          # A ROOM SHARED WITH THE OTHER SPRITES OF THIS SCREEN SHOWING THE SAME PICTURES (see
          # SharedRooms). The first of them to be placed lays out every room and stores the
          # frames, once for all of them; each is numbered among them, which is how the running
          # game says which room it holds. A pose's pieces are laid out the same way in every
          # room, so its record points at the first room, and the room it draws from is added
          # while the game runs.
          def shared_room_placement(pictures, sharing)
            rooms = (@rooms_of[sharing] ||= lay_out_shared_rooms(pictures, sharing.size))
            { starts: pictures.room_starts, alike: pictures.one_shape?, per_pose: 0,
              tiles: nil, tile_units: rooms.units, tile_index: rooms.first,
              frames: rooms.frames, frame_bytes: rooms.frame_bytes,
              rooms: rooms, room_member: sharing.index(pictures.name) }
          end

          def lay_out_shared_rooms(pictures, count)
            blob = :"__obj_frames_#{pictures.name}"
            @blobs.store_unpacked(blob, pictures.frames)
            units = pictures.frame_bytes / 32
            first = @art.reserve(units * count, narrow: pictures.place.narrow?)
            @rooms_bytes[@screen] = @rooms_bytes.fetch(@screen, 0) + (units * count * 32)
            SharedRooms.new(first: first, units: units, count: count, frames: blob,
                            frame_bytes: pictures.frame_bytes).tap { |rooms| @shared_rooms << rooms }
          end
        end
      end
    end
  end
end
