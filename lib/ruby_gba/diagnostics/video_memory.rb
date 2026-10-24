# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # HOW MUCH ROOM THE PICTURES TOOK, and how much the framework's own choice bought back.
    #
    # A console keeps the pictures it draws in a memory of its own, and it is small and fixed:
    # 32K for the sprites, a block of the same size for the tiles a background is built from.
    # Running out is a build error rather than a slow frame, so the number worth reporting is
    # how much is LEFT — and, because a game grows and nobody watches this until it breaks,
    # it is worth reporting before it breaks.
    #
    # The second half is the part nobody could work out for themselves. The framework stores a
    # picture drawn from few enough colors at half the size, silently, deciding from the art
    # rather than from anything in the program — so how much of the room in hand came from that
    # decision is invisible unless the build says. It is usually most of it.
    VideoMemory = Data.define(:sprites, :tiles, :objects) do
      def initialize(objects: nil, **rest) = super

      def any? = !sprites.nil? || !tiles.nil?

      def to_h
        { sprites: sprites&.to_h, tiles: tiles&.to_h, objects: objects&.to_h }.compact
      end
    end

    class VideoMemory
      # One of the two areas. +small+ and +big+ are how many pictures got each storage, and
      # +saved+ is what the small ones would have cost stored the big way — which is their own
      # size again, since the small way is exactly half. +shared+ is how many pictures turned
      # out to be one another and were stored once. +mirrored+ is how many background tiles
      # turned out to be another tile reversed, and are drawn from it turned round.
      #
      # +repeats+ is bytes a picture did not cost because part of it was already there. A
      # sprite's poses are stored as pieces, and most of a character does not change between
      # two frames of a walk — the head, the torso, the arm that is not moving — so the
      # pieces that did not change are stored once and every frame points at them. This is
      # the one saving a game written straight against the console cannot have, since an
      # object reads a contiguous run of tiles and every frame there has to be its own run.
      #
      # +skipped+ is bytes nothing draws from. A background layer names its tiles by counting
      # from a starting point, and a game with more tiles than one layer can count across gets
      # a second starting point — which the console only allows at fixed marks, so lining a
      # layer up with one can leave a gap behind it. Nobody writes any of that, and the gap is
      # otherwise invisible, so it is worth a number.
      # +one_frame+ is how many sprites keep one frame in this memory at a time, their other
      # frames waiting in the cartridge — which is the other way a picture comes to cost nothing
      # here, and a different thing from sharing: a shared picture is in this memory once for
      # everyone showing it, where these are copied in as the sprite animates.
      #
      #
      # +screens+ is the sprites' half of the same question asked of each scene in turn (see
      # Screen), since the fullest scene is not always the one a game grows in. Empty for tiles.
      #
      # +start+ is the address of the area's first tile in the console's memory, which is what a
      # tile number in +screens+ counts from (see Placed#address). nil for the tiles' area.
      Area = Data.define(:used, :capacity, :small, :big, :saved, :shared, :mirrored, :repeats, :skipped,
                         :one_frame, :screens, :start) do
        def initialize(mirrored: 0, repeats: 0, skipped: 0, one_frame: 0, screens: [], start: nil, **rest) = super

        def free = capacity - used
        def share = capacity.zero? ? 0.0 : used.to_f / capacity

        def to_h
          { used: used, capacity: capacity, free: free, small: small, big: big,
            saved: saved, shared: shared, mirrored: mirrored, repeats: repeats, skipped: skipped,
            one_frame: one_frame, screens: screens.map(&:to_h), start: start }.compact
        end

        # Every scene's sprites and where each one's pictures are, as text to print:
        # `puts rom.sprite_memory`.
        def to_s = screens.map(&:to_s).join("\n")
      end

      # Sprite and background memory both count in tiles of this many bytes, and a tile number
      # is how far into the area a tile starts, in these.
      TILE_BYTES = 32

      # ONE SCENE'S SPRITE MEMORY, with the pictures every screen shows: +scene+ as the author
      # named it, or nil in a game with no scenes. +used+ is what it takes. +room_bytes+ is how
      # much of that is rooms that sprites kept to one frame share, a room for each sprite that
      # can show their pictures at once, so that what is used there follows what is on screen;
      # the rest is +fixed+. +least_needed+ is what the scene would take if every set of pictures
      # that animates kept only that. The build keeps whole every set that fits, since a set kept
      # whole copies nothing as it plays, so the least is how far from the wall the scene really is.
      # Where the build stopped on sprite memory it never worked the least out, and it is +used+.
      #
      # +sprites+ is every sprite up in that scene, its own and the ones every scene shows, each
      # with the tiles it was given (see Placed). +own_from+ is the first tile of the scene's own:
      # the tiles before it hold what every screen shows and are left alone as scenes change, and
      # the tiles from it on are written again as the scene takes over.
      Screen = Data.define(:scene, :used, :room_bytes, :least_needed, :sprites, :own_from) do
        def initialize(sprites: [], own_from: 0, **rest) = super

        def fixed = used - room_bytes

        # The bytes nobody's pictures are in: a picture stored the big way starts on an even tile,
        # and one stored the small way before it can leave one empty.
        def gaps = used - (distinct_runs.sum { |_, tiles| tiles } * TILE_BYTES)

        # What sprites drawing from a run another sprite here already holds did not cost: every
        # sprite's run as if it were alone, less the runs there are.
        def saved_by_sharing
          (sprites.sum { |entry| entry.tiles_alone * entry.count } - distinct_runs.sum { |_, tiles| tiles }) * TILE_BYTES
        end

        def to_h = super.merge(sprites: sprites.map(&:to_h), gaps: gaps, saved_by_sharing: saved_by_sharing)

        # This scene's sprites, one a line, in the order their tiles start.
        def to_s
          title = scene ? "scene :#{scene}" : "every screen"
          lines = sprites.sort_by { |entry| [entry.first_tile, entry.sprite.to_s] }.map(&:line)
          summary = "#{title}: #{used} bytes of sprite memory, #{saved_by_sharing} saved by sharing" \
                    "#{", #{gaps} in gaps" if gaps.positive?}; its own pictures from tile #{own_from}"
          ([summary, "  first  tiles  address     held           sprite: pictures"] + lines).join("\n")
        end

        private

        def distinct_runs = sprites.map { |entry| [entry.first_tile, entry.tiles] }.uniq
      end

      # WHERE ONE SPRITE'S PICTURES ARE IN SPRITE MEMORY, in one scene. +first_tile+ and +tiles+
      # are the run of tiles it draws from, and +address+ the first of them in the console's
      # memory, to lay against a reading of it. +pictures+ are the names of the pictures it shows.
      # +pieces+ is how many of the console's sprites each picture is drawn as, one for a picture
      # the console can draw in one go; +poses+ is each picture with the first tile of each of its
      # pieces.
      #
      # +held+ says what is in that run. :whole is every picture it shows, put there as its scene
      # takes over and left alone. The rest are rewritten while the game runs: :one_frame is room
      # for the frame it is showing, copied in as it changes; :shared_rooms is a room for each of
      # the sprites of its scene showing these pictures, which they take turns at; :painted is a
      # picture the game paints from a list; :sent_as_shown is a pool's pictures, each copied in
      # the first time it is shown.
      #
      # +sprite+ is the name the game wrote, nil for a sprite it named nothing (a letter of text
      # on a screen drawn from tiles), and +count+ how many sprites of that name draw from this
      # run: more than one for a pool, whose slots all show the same pictures. +tiles_alone+ is
      # what one of them would take by itself — the whole run, but for sprites taking turns at
      # shared rooms, where it is one room. +shares_with+ is the other sprites of the scene
      # drawing from the same run.
      Placed = Data.define(:sprite, :count, :pictures, :first_tile, :tiles, :tiles_alone, :address, :pieces,
                           :poses, :held, :shares_with) do
        def bytes = tiles * TILE_BYTES
        def rewritten? = held != :whole

        def to_h = super.merge(bytes: bytes, rewritten: rewritten?)

        def line
          many = count > 1 ? " (#{count} of them)" : ""
          cut = pieces > 1 ? " in #{pieces} pieces" : ""
          shared = shares_with.empty? ? "" : " (shared with #{shares_with.map { |name| name || 'text' }.join(', ')})"
          format("  %5d  %5d  0x%08X  %-13s  %s%s%s: %s%s", first_tile, tiles, address, Placed::HELD_WORDS.fetch(held),
                 sprite || "text", many, cut, pictures.join(", "), shared)
        end
      end

      class Placed
        HELD_WORDS = { whole: "all", one_frame: "one frame", shared_rooms: "shared rooms", painted: "painted",
                       sent_as_shown: "sent as shown" }.freeze
      end

      # HOW MANY OF THE CONSOLE'S SPRITES THE GAME SPENDS, which is not the same number as
      # how many sprites the author declared. The console draws 128 at once, and a picture
      # bigger than the largest one of them is drawn as SEVERAL standing shoulder to
      # shoulder — so a boss can quietly cost nine. Nobody writes that, and it comes out of
      # the same 128 as everything else, so it is worth a number.
      #
      # +big+ is [picture name, how many objects] for each sprite spending more than one,
      # and +twins+ is what the windows that hold a placed fade off a sprite cost, since
      # each of those shadows a sprite object for object.
      Objects = Data.define(:used, :capacity, :big, :twins) do
        def initialize(big: [], twins: 0, **rest) = super

        def free = capacity - used

        def to_h
          { used: used, capacity: capacity, free: free,
            big: big.map { |name, count| { name: name, objects: count } }, twins: twins }
        end
      end
    end
  end
end
