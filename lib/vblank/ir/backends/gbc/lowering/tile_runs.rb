# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # TILES THE GAME PAINTS FROM A LIST (`tiles :box, from: list, count: n`), lowered for a Game
          # Boy Color. Mixed into Lowering.
          #
          # The list holds each tile as the Advance's picture memory does: 32 bytes, two pixels a
          # byte, the left one in the low four bits. The Color keeps a tile in 16 bytes, two to a
          # row, the low bit of every pixel of the row in the first and the high bit in the second.
          # So a copy is a repacking, done by the processor (Runtime::Picture's rt_repack_tiles) into
          # a stretch of work memory kept for the run, while the screen is being drawn; and the
          # console's own copying puts that into picture memory in the next blank, which is the gap
          # between frames the interpreter copies in (Reference#exec_copy_owed_tiles). Each painted
          # tile has a tile of its own in picture memory (GBC::Art#run_tile), and so does every piece
          # of a sprite's picture painted from a list (GBC::Art#painted_sprite_picture), whose list
          # keeps its tiles in the order a sprite's pieces are kept.
          module TileRuns
            STATEMENTS = Ractor.make_shareable({ copy_tiles: :emit_copy_tiles, copy_owed_tiles: :emit_copy_owed_tiles })

            # Where a run's repacked tiles wait for the blank, and its flag saying they are waiting,
            # with where in picture memory each of its tiles goes — its bank and its address — for the
            # runtime's copy (Runtime::Picture).
            RunUpload = Data.define(:owed, :staging, :tiles)

            # Bytes a tile takes in the Color's picture memory.
            TILE_BYTES = 16

            # Every painted run's copy, for the runtime, once #keep_tile_runs has placed them.
            def run_uploads
              (@run_places || {}).filter_map do |name, (owed, staging)|
                RunUpload.new(owed: owed, staging: staging, tiles: run_tile_places(tile_runs.fetch(name)))
              end
            end

            private

            def tile_runs = @tile_runs ||= by_name(@program.walk, :tile_run)

            # The run a painted tile is one of, or nil for a tile drawn when the game was built.
            def run_painting(name) = tile_runs.each_value.find { |run| run.tiles.include?(name) }

            # The run a sprite's picture is painted from, or nil for one drawn when the game was built.
            def picture_painting(name) = tile_runs.each_value.find { |run| run.picture == name }

            # The colours a painted picture shows, by place: its run's, or +colors+ in their place
            # where it is drawn with another list (Assets::Recolor's rule, by place).
            def painted_colors(run, colors)
              return run.colors unless colors

              Array.new([[run.colors.length, colors.length].max, Art::PLACES].min) { |place| colors[place] || run.colors.fetch(place, 0) }
            end

            # Where each of a run's tiles goes in picture memory, as [bank, address]: a background
            # tile's 256 to a bank, the first 128 from 0x9000 and the rest from 0x8800; a sprite's
            # pieces 128 to a bank from 0x8000.
            def run_tile_places(run)
              if run.picture
                @art.painted_sprite_picture(run.picture, run.width, run.height).pieces.map do |piece|
                  [piece.tile / 128, 0x8000 + ((piece.tile % 128) * TILE_BYTES)]
                end
              else
                run.tiles.map do |tile|
                  number = @art.run_tile(tile, run.colors).first
                  m = number % 256
                  [number / 256, (m < 128 ? 0x9000 : 0x8000) + (m * TILE_BYTES)]
                end
              end
            end

            # How many tiles a run's list holds.
            def run_tile_count(run) = run.picture ? (run.width / 8) * (run.height / 8) : run.tiles.length

            # The tile number and palette number a background's tile +name+ is drawn with, as +room+ numbers
            # it (GBC::Art#background_tile; nil for the tiles every screen keeps): a painted
            # tile's own (GBC::Art#run_tile), or a drawn one's (GBC::Art#background_tile).
            def background_tile_named(name, room = nil)
              run = run_painting(name)
              return @art.run_tile(name, run.colors) if run

              @art.background_tile(name, Assets::Image.of(@pictures.fetch(name)), room: room, recolor_steps: recolor_steps_of(name),
                                                                                  empty_cells_shown: empty_cells_shown_with?(room))
            end

            # Each run's flag and its repacked tiles' stretch of work memory, which the console's copy
            # reads from an address that is a multiple of 16.
            def keep_tile_runs
              @run_places = tile_runs.values.to_h do |run|
                owed = @memory.reserve("the painted tiles #{run.name.inspect}, waiting", 1)
                room = @memory.reserve("the painted tiles #{run.name.inspect}", (run_tile_count(run) * TILE_BYTES) + 15)
                [run.name, [owed, (room + 15) & ~15]]
              end
            end

            # Reference#exec_copy_tiles: the run's list repacked now, and put in at the next blank.
            def emit_copy_tiles(node) = emit_run_copy(tile_runs.fetch(node.name))

            # Reference#exec_copy_owed_tiles: every run whose bit is set in the game's own flags, in
            # the order they were declared.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                mask = @variables.fetch(node.masks.fetch(i / per))
                bit = i % per
                past = fresh("past_the_run")
                @asm.load(:a, [mask + (bit / 8)])
                @asm.bit(bit % 8, :a)
                @asm.jump(:z, past)
                emit_run_copy(tile_runs.fetch(name))
                @asm.label(past)
              end
            end

            def emit_run_copy(run)
              list, = @lists.fetch(run.list) { raise LoweringError, "the list #{run.list.inspect} is painted from and never declared" }
              owed, staging = @run_places.fetch(run.name)
              @asm.load(:hl, list + Runtime::Lists::HEADER)
              @asm.load(:de, staging)
              @asm.load(:bc, run_tile_count(run))
              @asm.call("rt_repack_tiles")
              @asm.load(:a, 1)
              @asm.load([owed], :a)
            end
          end
        end
      end
    end
  end
end
