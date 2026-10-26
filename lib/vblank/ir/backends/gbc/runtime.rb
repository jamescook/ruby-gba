# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/calls"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/picture_groups"
require_relative "runtime/paint"
require_relative "runtime/sound"
require_relative "runtime/music"
require_relative "runtime/effects"
require_relative "runtime/big_maps"
require_relative "runtime/saving"

module VBlank
  module IR
    module Backends
      class GBC
        # THE RUNTIME every Game Boy Color cartridge carries, in bank 0 where every routine of the
        # game can reach it: from power-on to the game's first line (Boot), the arithmetic (Int32),
        # calls between banks and the runtime's numbers (Calls), the frame and the buttons (Frame),
        # the lists (Lists), the picture (Picture, and Paint for a painted screen) and the sound
        # (Sound).
        #
        # The game's code (GBC::Lowering) calls its routines by their labels (rt_wait_vblank,
        # rt_list_push, rt_held...), with the numbers on the stack (Runtime::Calls).
        module Runtime
          module_function

          # The runtime's own places in work memory, asked for before the game's, so they are in
          # the half always in view (a painted screen puts its banks in the other half while it
          # works). +art+ is what the game's pictures were made into (GBC::Art), +effects+ its sound
          # effects (GBC::Music#effects). +together+ says it has picture groups with more than one
          # slot (Frame#emit_groups_together).
          def reserve(memory, art:, effects: [], together: false)
            Frame.reserve(memory, together: together)
            Picture.reserve(memory, lends: art.lends?, groups: art.groups?)
            BigMaps.reserve(memory)
            Paint.reserve(memory, painting: art.painting?)
            Music.reserve(memory, effects: effects)
          end

          # The runtime's sections: the processor's entry points, and everything else in one.
          # +main+ is the label of the game's main routine, called in its own bank; +art+ is what its
          # pictures were made into (GBC::Art), which the runtime puts in the console at power-on;
          # +music_level+ is where the game keeps how loud its music is (nil for at full), +songs+
          # whether it has any songs at all, +music+ its songs and sound effects (GBC::Music, nil for
          # none), and +frame_begins+ the label of the game's routine run at each frame boundary
          # (its timers moving on, GBC::Timers), or nil for none. +runs+ are the tiles it paints from
          # lists (Lowering::TileRuns#run_uploads), and +drawn_palettes+ where it keeps the colours its
          # pictures are drawn in now, for a game that draws a background in others (nil for none).
          # +big_maps+ is where a game with a map bigger than the grid keeps its copy of the grid and
          # the list of cells for the blank (Runtime::BigMaps), or nil. +together+ is as for #reserve.
          def sections(memory, main:, art:, music_level: nil, songs: false, music: nil, frame_begins: nil, runs: [],
                       drawn_palettes: nil, big_maps: nil, together: false)
            asm = SM83.new("runtime", home: :fixed)
            Boot.emit(asm, main: "rt_main")
            Boot.emit_display_off(asm)
            Boot.emit_clear(asm)
            Int32.emit(asm, memory)
            Calls.emit(asm, memory)
            Frame.emit(asm, memory, together: together)
            Lists.emit(asm, memory)
            Picture.emit(asm, memory, sprite_tiles: art.sprite_tiles.length, background_tiles: art.background_tiles.length,
                                      runs: runs, drawn_palettes: drawn_palettes, lends: art.lends?,
                                      palettes_in_use: art.palettes_in_use, groups: art.groups?)
            BigMaps.emit(asm, memory, buffer: big_maps&.first, staged: big_maps&.last)
            Paint.emit(asm, memory, painting: art.painting?, map_count: art.square_maps.length)
            Sound.emit(asm)
            Music.emit(asm, memory, level: music_level, songs: songs, effects: music&.effects || [],
                                    by_rank: music&.effects_by_rank || [])
            Saving.emit(asm, memory)
            emit_start(asm)
            emit_main(asm, main)
            emit_frame_begins(asm, frame_begins)
            [*Boot.vector_sections, asm.section, *Paint.table_sections(maps: art.square_maps)]
          end

          # What a game needs before its first line: its variables that do not start at nought,
          # its lists' headers, and the buttons held from power-on.
          def emit_start(asm)
            asm.label("rt_start")
            asm.load(:hl, "game_starts")
            asm.label("rt_start_next")
            asm.load(:a, [:hli])
            asm.load(:e, :a)
            asm.load(:a, [:hli])
            asm.load(:d, :a)
            asm.or_a(:e)
            asm.jump_relative(:z, "rt_start_lists")
            4.times do
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
            end
            asm.jump_relative("rt_start_next")
            asm.label("rt_start_lists")
            asm.call("rt_lists_start")
            asm.call("rt_picture_start")
            asm.call("rt_paint_start")
            asm.jump("rt_buttons_from_power_on")
          end

          # The game's main routine, in whichever bank it went to.
          def emit_main(asm, main)
            asm.label("rt_main")
            asm.call("rt_far_call")
            asm.data_bank_of(main)
            asm.data_words(main)
            asm.ret
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+ in whichever bank it went to,
          # or nothing for a game with none. The music moves on from the frame's interrupt instead.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            if routine
              asm.call("rt_far_call")
              asm.data_bank_of(routine)
              asm.data_words(routine)
            end
            asm.ret
          end
        end
      end
    end
  end
end
