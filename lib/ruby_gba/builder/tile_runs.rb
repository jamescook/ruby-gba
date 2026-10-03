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
        record(Build.set(tile_run_pending(name), Build.int(1)))
        @inline_tile_copies << record(Build.copy_tiles(name))
      end

      private

      def tile_run_pending(name) = Messages::MadeNames.make(:tile_run_pending, run: name)

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
        images.each { |image| @images[image] = [8, 8] }
        record(Build.tile_run(name, list: list.name, tiles: images, colors: colors))
        at_boot(Build.set(tile_run_pending(name), Build.int(0)))
        ensure_var(tile_run_pending(name))
        @tile_runs << name

        tiles(name, images.each_with_index.to_h { |image, i| [i + 1, image] }.merge(tile_map))
        DSL::TileRun.new(self, name)
      end

      # COPY EACH RUN WHOSE LIST MOVED, in the gap between frames, and only on a frame where
      # the game said so. Saying `changed` sets a flag; the gap copies and clears it. That is
      # what makes three `changed` in one frame one copy, and what keeps the copy out of the
      # middle of a frame, where the top of the screen would show the old pixels and the
      # bottom the new.
      def finalize_tile_copies
        return if @tile_runs.empty? || @frame_boundaries.empty?

        @inline_tile_copies.each { |node| node.parent&.children&.delete(node) }
        @frame_boundaries.each do |wait_node|
          container = wait_node.parent
          at = container&.children&.index(wait_node)
          next unless at

          @tile_runs.reverse_each do |name|
            pending = tile_run_pending(name)
            node = Build.if_(Build.binop(:!=, Build.var_ref(pending), Build.int(0)),
                             Build.copy_tiles(name), Build.set(pending, Build.int(0)))
            container.children.insert(at + 1, node)
            node.parent = container
          end
        end
      end

      # The run's colours, place 0 first: a list declared with `colors`, by name, or the
      # colours themselves.
      def tile_run_colors(name, colors)
        list = colors.is_a?(Symbol) ? @color_lists[colors] : colors
        if list.nil? && colors.is_a?(Symbol)
          raise ArgumentError, "tiles :#{name} draws from colors :#{colors}, and no list has that name. " \
                               "Declare it first with `colors :#{colors}, [:transparent, ...]`."
        end
        unless list.is_a?(Array) && list.length.between?(2, Images::OWN_COLORS)
          raise ArgumentError, "tiles :#{name} needs `colors:`: a list of 2 to #{Images::OWN_COLORS} colors, " \
                               "the first meaning see-through. Each four bits of the list's bytes picks one."
        end
        list.map do |color|
          next color if color.is_a?(Integer) # a `colors` list, already resolved

          color == :transparent ? 0 : Graphics::Color.resolve(color)
        end
      end

      def refuse_tile_run_on_bitmap_screen!(name)
        return unless @screen_mode == :bitmap

        raise ArgumentError, "tiles :#{name} gets its pixels from a list, and this screen is a bitmap. A bitmap " \
                             "screen has no tiles to copy the list into. To draw pixels the game works out " \
                             "on it, use `pixel` or `blit`."
      end

      def refuse_bad_tile_run_count!(name, count)
        return if count.is_a?(Integer) && count.positive?

        raise ArgumentError, "tiles :#{name} needs `count:`, how many tiles the list holds. It must be a whole " \
                             "number, 1 or more. Got #{count.inspect}."
      end

      def refuse_tile_run_list_unfit!(name, list, count)
        made = @program.walk.find { |node| node.kind == :list_new && node.name == list.name }
        unless made&.width == :byte
          raise ArgumentError, "tiles :#{name} gets its pixels from list :#{list.name}, which must hold bytes. " \
                               "To fix this, declare it with `width: :byte`."
        end
        needed = count * TILE_BYTES
        return if made.capacity >= needed

        raise ArgumentError, "tiles :#{name} has #{count} tiles, and each tile is #{TILE_BYTES} bytes of its " \
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
