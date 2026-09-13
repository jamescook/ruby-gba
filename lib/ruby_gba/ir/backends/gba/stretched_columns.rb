# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Where a see-through picture's columns hold pixels (see StretchedColumns): the
        # stretches themselves, and where each column's list of them starts.
        #
        # A row number is one byte, so a picture taller than this ships none and walks its
        # whole height, as every picture did before there were lists. Any height up to it
        # ships them — turning a picture row into a screen row divides by the height, and a
        # height that is not a power of two divides by a multiply the build settles rather
        # than by a shift (see Framebuffer::ColumnDivide).
        RUNS_SUFFIX = "__runs"
        RUNS_START_SUFFIX = "__runstart"
        RUNS_MAX_ROWS = 256
        # The byte that ends a column's list. No row can be it, because a picture that tall
        # ships no runs at all.
        RUNS_END = 255
        RUNS_MAX_BYTES = 0xFFFF

        # WHAT THE BUILD COULD DO FOR ONE SEE-THROUGH PICTURE a stretched column reads:
        # whether it ships where each of its columns holds pixels, and what stopped it when
        # it does not. +held_back_by+ is nil when it ships, :too_tall for a picture past
        # RUNS_MAX_ROWS, and :too_many when its lists together run past RUNS_MAX_BYTES.
        #
        # A picture that ships none walks EVERY row of every column it draws, and a see-through
        # picture is mostly rows that draw nothing — so this is the difference between a lamp
        # costing its lit rows and costing its square. Nothing about how the game runs reads it;
        # it is here so the report can say what happened.
        ColumnStretches = Data.define(:height, :held_back_by) do
          def skips_empty_rows? = held_back_by.nil?
        end

        # EVERY PICTURE A STRETCHED COLUMN DRAWS, and what the build settled about each.
        #
        # A stretched column walks down the screen asking each row for a pixel, and for a
        # picture that is mostly see-through most of those rows answer "nothing here". A
        # scaled sprite is exactly that: a lamp, a barrel, a clip of ammunition, each in the
        # middle of a square of see-through. So the build works out, per column, the stretches
        # of rows that hold pixels, ships them beside the picture, and the walk goes round once
        # per stretch instead of once down the square.
        #
        # Three questions come out of that and they are all the same fact, which is why they
        # are one object: whether a picture needs its pixels in the cartridge at all (only a
        # stretched column reads a see-through one), whether its walk goes stretch by stretch
        # or row by row, and what to tell somebody whose picture missed.
        class StretchedColumns
          def initialize(program, emitter:)
            @emitter = emitter
            @drawn_as_columns = program.walk.filter_map { |node| node.name if node.kind == :draw_column_at }.uniq
            @decided = {}
          end

          # Does a stretched column read this picture? A see-through picture is otherwise
          # drawn pixel by pixel with its colors baked into the code and needs no copy in the
          # cartridge; this walks it as the game runs, so it does.
          def reads?(name) = @drawn_as_columns.include?(name)

          # Does this picture's walk go stretch by stretch? A picture that ships no list is
          # drawn in one pass over its full height, which is what every picture did before
          # there were lists and what an opaque one still does.
          def skips_empty_rows?(name)
            picture = @decided[name]
            !picture.nil? && picture.skips_empty_rows?
          end

          # What the lists are filed under, beside the picture's colors.
          def runs_blob(name) = :"#{name}#{RUNS_SUFFIX}"
          def runs_start_blob(name) = :"#{name}#{RUNS_START_SUFFIX}"

          # What the build settled for each picture, for the report.
          def to_h = @decided.dup

          # WHERE EACH COLUMN OF A SEE-THROUGH PICTURE HOLDS PIXELS, as the stretches of rows
          # that hold them. Called for every picture; one no stretched column draws, and an
          # opaque one, keep nothing.
          #
          # THE STRETCHES AND NOT JUST THE FIRST AND LAST. A thing lying on the floor holds its
          # pixels in the bottom sixth of its column and one band would catch that — but a lamp
          # that hangs holds them at the TOP of its column and at the bottom, with the ceiling
          # between, and the gap in the middle is where a player standing under it is looking.
          # Measured on a real floor: the first-and-last band leaves 30 rows walked in every
          # hundred, and the stretches leave 17.
          #
          # A column that holds nothing at all gets an empty list, so it walks no rows.
          def register(node)
            return unless node.transparent && reads?(node.name)

            @decided[node.name] = ColumnStretches.new(height: node.height, held_back_by: ship(node))
          end

          private

          # ...done, and what stopped it: nil when the picture ships its stretches, else which
          # of the two ceilings it ran into.
          def ship(node)
            return :too_tall if node.height > RUNS_MAX_ROWS

            runs = column_runs(node)
            starts = []
            at = 0
            runs.each do |column|
              starts << at
              at += (column.length * 2) + 1 # a pair of rows each, then the byte that ends the list
            end
            # Where a column's list starts is a halfword, so a picture whose lists together run
            # past that ships none and walks its whole height, as every picture did before there
            # were lists.
            return :too_many if at > RUNS_MAX_BYTES

            @emitter.data_blobs[runs_blob(node.name)] =
              runs.flat_map { |column| column.flat_map { |run| [run.first, run.last] } << RUNS_END }
                  .pack("C*")
            @emitter.data_blobs[runs_start_blob(node.name)] = starts.pack("v*")
            nil
          end

          def column_runs(node)
            pixels = node.pixels.unpack("v*")
            (0...node.width).map do |x|
              rows = (0...node.height).select { |y| pixels[(y * node.width) + x] != node.transparent }
              rows.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
            end
          end
        end
      end
    end
  end
end
