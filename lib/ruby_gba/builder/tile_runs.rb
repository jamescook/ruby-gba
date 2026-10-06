# frozen_string_literal: true

module RubyGBA
  class Builder
    # TILES WHOSE PIXELS THE GAME PAINTS AS IT RUNS: `tiles :box, from: list, count: n`.
    #
    # Every other tile is a picture fixed while the cartridge is built, uploaded once and
    # merged with any tile that came out the same. These are the opposite on every count. The
    # pixels live in a list the game owns and writes as it likes, so nothing about them is
    # known while the game is built — a name, a score, a message typed a letter at a time, a
    # meter, a map drawn from where the player has been. They are never merged, because two of
    # them that look the same now may not on the next frame. And they reach the screen only
    # when the game says `changed`, which copies the whole list in the gap between frames.
    #
    # The list holds the pixels the way the console's video memory does, so the copy is a
    # plain copy and a game can match another cartridge's buffer byte for byte: one byte is two
    # pixels, the left one in the low four bits, and each four bits is a place in the run's
    # colour list, place 0 see-through. A tile is eight rows of four bytes.
    module TileRuns
      # Bytes one tile of a run takes in its list: 8 rows of 8 pixels, two pixels a byte.
      TILE_BYTES = 32

      # The game says the list moved (see DSL::TileRun#changed). Where the program is paced by
      # frames the copy waits for the gap after this frame — see #finalize_tile_copies — and
      # the flag set here is what tells it to; where it is not, the copy stays where it was
      # asked for, since there is no gap to move it to.
      def request_tile_copy(name)
        mask = tile_run_pending(name)
        record(Build.set(mask, Build.binop(:|, Build.var_ref(mask), Build.int(tile_run_bit(name)))))
        @inline_tile_copies << record(Build.copy_tiles(name))
      end

      private

      # WHICH RUNS ARE OWED A COPY, as bits of a few variables rather than a flag apiece: a bit
      # per run, thirty to a variable so a mask never reaches the sign bit. That is what lets
      # the gap between frames ask one question of all of them (see #finalize_tile_copies).
      RUNS_PER_MASK = 30

      def tile_run_pending(name) = Messages::MadeNames.make(:tile_run_pending, number: @tile_runs.index(name) / RUNS_PER_MASK)
      def tile_run_bit(name) = 1 << (@tile_runs.index(name) % RUNS_PER_MASK)

      # The run's place among the runs is settled as it is declared, which is where its mask
      # starts at nought — once for each mask, however many runs share it.
      def register_tile_run(name)
        @tile_runs << name
        mask = tile_run_pending(name)
        return unless (@tile_runs.index(name) % RUNS_PER_MASK).zero?

        at_boot(Build.set(mask, Build.int(0)))
        ensure_var(mask)
      end

      def tile_run_masks = @tile_runs.map { |name| tile_run_pending(name) }.uniq

      # `tiles` given a list rather than a picture file. The run's tiles are keyed 1 to
      # +count+ in the order their bytes sit in the list, and any other keys are ordinary
      # tiles drawn beside them — a box's frame round the run, say.
      def define_tile_run(name, tile_map)
        tile_map = tile_map.dup
        list = tile_map.delete(:from)
        count = tile_map.delete(:count)
        colors = tile_run_colors(name, tile_map.delete(:colors))
        refuse_tile_run_on_bitmap_screen!(name)
        refuse_bad_tile_run_count!(name, count)
        refuse_tile_run_list_unfit!(name, list, count)
        refuse_tile_run_key_taken!(name, tile_map, count)

        images = (1..count).map { |number| Messages::MadeNames.make(:tile_run_tile, run: name, number: number) }
        images.each do |image|
          @images[image] = [8, 8]
          @painted_colors[image] = colors
        end
        record(Build.tile_run(name, list: list.name, tiles: images, colors: colors))
        register_tile_run(name)

        tiles(name, images.each_with_index.to_h { |image, i| [i + 1, image] }.merge(tile_map))
        DSL::TileRun.new(self, name)
      end

      # THE SIZES THE CONSOLE DRAWS A SPRITE AT, in pixels across and down. A picture painted
      # from a list is one of these whole, rather than cut into pieces the way a bigger drawn
      # picture is, because the game writes its bytes in the order one sprite keeps its tiles.
      PICTURE_SIZES = Ractor.make_shareable([[8, 8], [16, 16], [32, 32], [64, 64], [16, 8], [32, 8], [32, 16],
                                             [64, 32], [8, 16], [8, 32], [16, 32], [32, 64]])

      # `image` given a list rather than art: a picture a sprite shows, painted by the game. Its
      # tiles are the list's 32-byte runs left to right and then top to bottom, which is the
      # order a sprite's tiles are kept in.
      def define_picture_run(name, opts)
        list = opts[:from]
        width = opts[:width]
        height = opts[:height]
        colors = tile_run_colors(name, opts[:colors], what: "image")
        refuse_tile_run_on_bitmap_screen!(name, what: "image")
        unless PICTURE_SIZES.include?([width, height])
          raise ArgumentError, "image :#{name} gets its pixels from a list, so it must be a size the console " \
                               "draws a sprite at. It is #{width.inspect}x#{height.inspect}. The sizes are " \
                               "#{PICTURE_SIZES.map { |w, h| "#{w}x#{h}" }.join(', ')}."
        end
        refuse_tile_run_list_unfit!(name, list, (width / 8) * (height / 8), what: "image")

        @images[name] = [width, height]
        @painted_colors[name] = colors
        record(Build.tile_run(name, list: list.name, tiles: [], colors: colors, picture: name,
                                    width: width, height: height))
        register_tile_run(name)
        DSL::TileRun.new(self, name)
      end

      # COPY EACH RUN WHOSE LIST MOVED, in the gap between frames, and only on a frame where
      # the game said so. Saying `changed` sets a flag; the gap copies and clears it. That is
      # what makes three `changed` in one frame one copy, and what keeps the copy out of the
      # middle of a frame, where the top of the screen would show the old pixels and the
      # bottom the new.
      #
      # THE GAME LOOP ASKS ONE QUESTION, however many runs there are: is any bit of any mask
      # set? Only then does it call the routine that copies — the one place the code for each
      # run lives. The game loop is run on every frame of every scene, so a check and a copy
      # written into it for each run were paid by every scene, the one the player plays in
      # included; and the routine runs only on a frame something was painted, so it is kept
      # in the cartridge rather than the quick memory.
      def finalize_tile_copies
        return if @tile_runs.empty? || @frame_boundaries.empty?

        @inline_tile_copies.each { |node| node.parent&.children&.delete(node) }
        declare_painted_copies_routine
        @frame_boundaries.each do |wait_node|
          container = wait_node.parent
          at = container&.children&.index(wait_node)
          next unless at

          any = tile_run_masks.map { |mask| Build.var_ref(mask) }.reduce { |a, b| Build.binop(:|, a, b) }
          node = Build.if_(Build.binop(:!=, any, Build.int(0)), Build.call(PAINTED_COPIES))
          container.children.insert(at + 1, node)
          node.parent = container
        end
      end

      # The routine the game loop calls on a frame with a run owed a copy.
      PAINTED_COPIES = Messages::MadeNames.make(:painted_copies)

      # Built here, once every run is known, rather than handed to `func`: the routines a game
      # wrote are built already. Listed with them so a call to it counts as one to a routine.
      def declare_painted_copies_routine
        @functions[PAINTED_COPIES] = proc {}
        push_container(Build.func(PAINTED_COPIES, fast: false)) do
          @tile_runs.uniq.each do |name|
            owed = Build.binop(:&, Build.var_ref(tile_run_pending(name)), Build.int(tile_run_bit(name)))
            record(Build.if_(Build.binop(:!=, owed, Build.int(0)), Build.copy_tiles(name)))
          end
          tile_run_masks.each { |mask| record(Build.set(mask, Build.int(0))) }
        end
      end

      # A LIST A RUN PAINTS FROM MUST NOT BE SHIFTED. Dropping the front item moves where the
      # first item lives — the list becomes a ring that wraps round its own memory — so its
      # bytes are no longer in the order the tiles read them. Refused here, once every routine
      # is built, so that a `shift` anywhere in the game is seen and both backends refuse it
      # alike rather than the interpreter drawing the shifted order and the console stopping.
      def refuse_shifted_tile_run_lists!
        return if @tile_runs.empty?

        runs = @program.walk.select { |node| node.kind == :tile_run }
        shifted = @program.walk.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }
        run = runs.find { |node| shifted.include?(node.list) } or return
        what = run.picture ? "image" : "tiles"
        raise ArgumentError, "#{what} :#{run.name} gets its pixels from list :#{run.list}, and the game also " \
                             "uses `shift` on that list. A shift moves the first item, so the bytes are no longer " \
                             "in the order that #{what} :#{run.name} reads them. To fix this, do not use `shift` " \
                             "on list :#{run.list}."
      end

      # The run's colours, place 0 first: a list declared with `colors`, by name, or the
      # colours themselves.
      def tile_run_colors(name, colors, what: "tiles")
        list = colors.is_a?(Symbol) ? @color_lists[colors] : colors
        if list.nil? && colors.is_a?(Symbol)
          raise ArgumentError, "#{what} :#{name} draws from colors :#{colors}, and no list has that name. " \
                               "Declare it first with `colors :#{colors}, [:transparent, ...]`."
        end
        unless list.is_a?(Array) && list.length.between?(2, Images::OWN_COLORS)
          raise ArgumentError, "#{what} :#{name} needs `colors:`: a list of 2 to #{Images::OWN_COLORS} colors, " \
                               "the first meaning see-through. Each four bits of the list's bytes picks one."
        end
        list.map do |color|
          next color if color.is_a?(Integer) # a `colors` list, already resolved

          color == :transparent ? 0 : Graphics::Color.resolve(color)
        end
      end

      def refuse_tile_run_on_bitmap_screen!(name, what: "tiles")
        return unless @screen_mode == :bitmap

        raise ArgumentError, "#{what} :#{name} gets its pixels from a list, and this screen is a bitmap. A bitmap " \
                             "screen has no tiles to copy the list into. To draw pixels the game works out " \
                             "on it, use `pixel` or `blit`."
      end

      def refuse_bad_tile_run_count!(name, count)
        return if count.is_a?(Integer) && count.positive?

        raise ArgumentError, "tiles :#{name} needs `count:`, how many tiles the list holds. It must be a whole " \
                             "number, 1 or more. Got #{count.inspect}."
      end

      def refuse_tile_run_list_unfit!(name, list, count, what: "tiles")
        made = (@program.walk.to_a + @boot_inits).find { |node| node.kind == :list_new && node.name == list.name }
        unless made&.width == :byte
          raise ArgumentError, "#{what} :#{name} gets its pixels from list :#{list.name}, which must hold bytes. " \
                               "To fix this, declare it with `width: :byte`."
        end
        needed = count * TILE_BYTES
        return if made.capacity >= needed

        raise ArgumentError, "#{what} :#{name} has #{count} tiles, and each tile is #{TILE_BYTES} bytes of its " \
                             "list, so list :#{list.name} needs a capacity of #{needed}. It has " \
                             "#{made.capacity}. To fix this, give the list a capacity of #{needed}."
      end

      def refuse_tile_run_key_taken!(name, tile_map, count)
        taken = tile_map.keys.select { |key| key.is_a?(Integer) && key.between?(1, count) }
        return if taken.empty?

        raise ArgumentError, "tiles :#{name}: keys 1 to #{count} are the tiles the list paints, and " \
                             "#{taken.map(&:inspect).join(', ')} also names a picture. To fix this, give that " \
                             "picture a key that is not 1 to #{count}."
      end
    end
  end
end
