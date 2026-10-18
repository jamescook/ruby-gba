# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/calls"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/paint"
require_relative "runtime/sound"
require_relative "runtime/music"

module RubyGBA
  module IR
    module Backends
      class GBC
        # THE RUNTIME every Game Boy Color cartridge carries, in bank 0 where every routine of the
        # game can reach it: from power-on to the game's first line (Boot), the arithmetic (Int32),
        # calls between banks and the runtime's numbers (Calls), the frame and the buttons (Frame),
        # the lists (Lists), the picture (Picture, and Paint for a painted screen) and the sound
        # (Sound).
        #
        # The game's code calls it by the names Native's runtime has (rg_wait_vblank, rg_list_push,
        # rg_held...), with the numbers on the stack, so the lowering the two share calls either
        # the same way.
        module Runtime
          module_function

          # The runtime's own places in work memory, asked for before the game's, so they are in
          # the half always in view (a painted screen puts its banks in the other half while it
          # works). +art+ is what the game's pictures were made into (GBC::Art).
          def reserve(memory, art:)
            Frame.reserve(memory)
            Picture.reserve(memory)
            Paint.reserve(memory, painting: art.painting?)
            Music.reserve(memory)
          end

          # The runtime's sections: the processor's entry points, and everything else in one.
          # +main+ is the label of the game's main routine, called in its own bank; +art+ is what its
          # pictures were made into (GBC::Art), which the runtime puts in the console at power-on;
          # +music_level+ is where the game keeps how loud its music is (nil for at full), and
          # +songs+ whether it has any songs at all.
          def sections(memory, main:, art:, music_level: nil, songs: false)
            asm = SM83.new("runtime", home: :fixed)
            Boot.emit(asm, main: "rt_main")
            Boot.emit_display_off(asm)
            Boot.emit_clear(asm)
            Int32.emit(asm, memory)
            Calls.emit(asm, memory)
            Frame.emit(asm, memory)
            Lists.emit(asm, memory)
            Picture.emit(asm, memory, sprite_tiles: art.sprite_tiles.length, background_tiles: art.background_tiles.length)
            Paint.emit(asm, memory, painting: art.painting?)
            Sound.emit(asm)
            Music.emit(asm, memory, level: music_level, songs: songs)
            emit_start(asm)
            emit_main(asm, main)
            emit_unfinished(asm)
            [*Boot.vector_sections, asm.section]
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

          # What the runtime does at each frame boundary that the Game Boy Color lowering does not
          # do anything for yet: nothing to move on.
          def emit_unfinished(asm)
            asm.label("rt_frame_begins")
            asm.ret
          end
        end
      end
    end
  end
end
