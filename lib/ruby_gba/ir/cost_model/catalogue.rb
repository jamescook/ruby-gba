# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Everything settled by walking the whole program once, before any per-node
      # price is asked: which screen each routine draws on, every
      # func/list/table/song/bitmap/object/backing-buffer declaration, and whether
      # any layer can be seen through.
      #
      # Built once per #analyze call (see #build) and handed to Pricing, Verdicts,
      # Tree, and Report as one immutable value — one seam, so it is always clear
      # which of them owns which fact, rather than each reading its own slice of a
      # dozen ivars on the CostModel instance.
      Catalogue = Data.define(:modes, :funcs, :capacities, :declared, :list_lengths,
                              :table_lengths, :songs, :bitmaps, :objects, :backing,
                              :sees_through) do
        # Walk the program once, in program order, and settle every question a later
        # price needs answered before it asks it: which routine draws where, what each
        # declaration means, and whether a layer can be seen through.
        def self.build(program)
          modes = resolve_modes(program)
          funcs = {}
          capacities = {}
          declared = {}
          list_lengths = {}
          table_lengths = {}
          songs = {}
          bitmaps = {}
          objects = {}
          backing = {}
          sees_through = false

          program.walk do |node|
            # Whether any layer can be seen through, which changes what a FADE costs — the
            # two share the display's one blend unit, so a fade in such a game decides
            # whether it is running or handing the blend back (see Pricing#fade_cost).
            sees_through ||= node.kind == :layers && node.transparency &&
                             Value.fixed_number(node.transparency) != 0
            funcs[node.name] = node if node.kind == :func
            capacities[node.name] = node.capacity if node.kind == :list_new
            # ...and the length the AUTHOR asked for, which is the most the list can really
            # reach. The ring rounds its size up to a power of two, and that headroom is for
            # the mask rather than for the game (see Build#list_new).
            declared[node.name] = node.declared || node.capacity if node.kind == :list_new
            # ...and how long the author says it usually is, which is a different question
            # and the only one a frame's real cost turns on (see Rollup#list_length).
            list_lengths[node.name] = node.usually if node.kind == :list_new && node.usually
            # How long a table is decides what a read of it costs, so it is read once here
            # from the declaration rather than at every read (see Pricing#table_read_weight).
            table_lengths[node.name] = node.values.length if node.kind == :table
            songs[node.name] = node if node.kind == :song
            bitmaps[node.name] = build_bitmap(node) if node.kind == :bitmap
            objects[node.name] = build_object(node) if node.kind == :object
            backing[node.name] = [node.width, node.height] if node.kind == :backing_buffer
          end

          new(modes: modes, funcs: funcs, capacities: capacities, declared: declared,
              list_lengths: list_lengths, table_lengths: table_lengths, songs: songs,
              bitmaps: bitmaps, objects: objects, backing: backing, sees_through: sees_through)
        end

        # Which screen each routine of the program draws on. A program that reaches one
        # drawing routine from two different screens can't be lowered at all, so there is
        # no mode to read and no cost to quote either — the build will say so, and every
        # op falls back to the boot screen (see Walker#current_mode).
        def self.resolve_modes(program)
          Modes.resolve(program)
        rescue Modes::Conflict
          nil
        end

        # What drawing one sprite costs, in the two ways a sprite can be more than a
        # position: it can be turned to an angle, and it can be drawn at a size. Both are
        # settled on the declaration — a sprite that never turns keeps a fixed angle
        # there — so they are read once here rather than at every frame's draw.
        def self.build_object(node)
          turns = !constant_operand?(node.angle, 0)
          resizes = resizes?(node)
          Sprite.new(turns: turns || resizes, resizes: resizes)
        end

        def self.resizes?(node) = !constant_operand?(node.scale, Build::SCALE_ONE)

        def self.constant_operand?(node, value)
          node.kind == :int && node.value == value
        end

        # What an image costs to draw, worked out once here rather than at every blit of
        # it. An image with no see-through color streams onto the screen in whole rows and
        # is priced by its size alone.
        #
        # One WITH a see-through color is drawn a pixel at a time, and then three numbers
        # matter. How many pixels are actually LIT (a see-through one is never written).
        # How many ROWS hold at least one (a row with none is skipped whole). And how many
        # of the lit pixels carry a color that needs a step of its own to build — because
        # drawing a pixel at a time means writing the color into every store, and only some
        # colors fit inside that instruction.
        #
        # Counting them is what stops a sprite that is mostly cut-out background from being
        # priced as a solid rectangle.
        def self.build_bitmap(node)
          see_through = node.transparent
          width = node.width
          height = node.height
          unless see_through
            return Bitmap.new(width: width, height: height, transparent: false,
                              lit_pixels: width * height, wide_color_pixels: 0, lit_rows: height,
                              column_rows: width * height)
          end

          # The pixels arrive as a run of 16-bit colors, row after row.
          all = node.pixels.unpack("v*")
          rows = all.each_slice(width).map { |row| row.reject { |px| px == see_through } }
          Bitmap.new(width: width, height: height, transparent: true,
                     lit_pixels: rows.sum(&:length),
                     wide_color_pixels: rows.sum { |row| row.count { |px| wide_color?(px) } },
                     lit_rows: rows.count { |row| !row.empty? },
                     column_rows: column_rows_walked(all, width, height, see_through))
        end

        # How many rows a stretched column really walks, added up over every column of the
        # picture: from the first row of a column that holds a pixel to the last, and nothing
        # in a stretch of see-through between two of them.
        #
        # This is what stops a scaled sprite being priced as a solid square. A lamp that hangs
        # is a picture of a lamp at the top of its square, a pool of light at the bottom, and
        # ceiling between — and the ceiling is most of the square and none of the cost.
        def self.column_rows_walked(pixels, width, height, see_through)
          (0...width).sum do |x|
            rows = (0...height).select { |y| pixels[(y * width) + x] != see_through }
            rows.slice_when { |a, b| b != a + 1 }.sum { |run| run.last - run.first + 1 }
          end
        end

        # Whether a color has to be built in a step of its own instead of riding inside the
        # instruction that writes it. The assembler makes this exact call every time it
        # loads a constant, so it is asked rather than restated here.
        def self.wide_color?(color) = ASM.encode_rotated_immediate(color).nil?

        # Whether any layer in the program can be seen through — the one field a reader
        # asks for by a name of its own rather than the field name (see Pricing#fade_cost).
        def sees_through_a_layer? = sees_through
      end
    end
  end
end
