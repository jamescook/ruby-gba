# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/paint"

module VBlank
  module IR
    module Backends
      class SNES
        # THE RUNTIME every Super Nintendo cartridge carries: from power-on to the game's first line
        # (Boot), the arithmetic (Int32), the frame and the buttons (Frame), the lists (Lists) and
        # the picture (Picture).
        #
        # HOW ITS ROUTINES ARE CALLED. With JSL (and they return with RTL), so a routine of the
        # game's in any bank calls them alike; with A, X and Y 16 bits wide, the direct page at
        # $0000 and the data bank at $80 (Boot sets all three, and every routine leaves them so);
        # with their numbers in the working numbers R0, R1, R2... on the direct page
        # (Memory.register), and their answer in R0. A routine may use every working number, A, X,
        # Y and the runtime's scratch as it likes.
        module Runtime
          module_function

          # The runtime's own places in work RAM, asked for before the game's. A game whose screen is
          # +painted+ (Paint) keeps its copy of the screen in work RAM's last bank.
          def reserve(memory, painted: false)
            Paint.reserve(memory) if painted
            Frame.reserve(memory)
            Picture.reserve(memory)
          end

          # The runtime's sections: the entry points in the first bank, and everything else in one.
          # +main+ is the label of the game's main routine; +frame_begins+ the label of the game's
          # routine run at each frame boundary (its timers moving on), or nil for none; +painted+
          # for a game whose screen is painted rather than drawn from tiles.
          def sections(memory, main:, frame_begins: nil, painted: false)
            vectors = W65816.new("runtime vectors", home: :first)
            Boot.emit_vectors(vectors)
            asm = W65816.new("runtime")
            Boot.emit(asm, main: main)
            Boot.emit_zero(asm)
            Int32.emit(asm, Int32.scratch(memory))
            Frame.emit(asm, memory, pad: memory.scratch(4))
            Lists.emit(asm, memory, Lists.scratch(memory))
            Picture.emit(asm, memory, work: memory.scratch(8), painted: painted)
            Paint.emit(asm, memory, Paint.scratch(memory)) if painted
            emit_start(asm)
            emit_frame_begins(asm, frame_begins)
            [vectors.section, asm.section]
          end

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place as a word and its number as two, and a place of nought
          # after the last), its lists' headers, the picture's start, the screen's interrupt
          # switched on, and the buttons held from power-on.
          def emit_start(asm)
            asm.label("rt_start")
            asm.ldx(0)
            asm.label("rt_start_next")
            asm.lda(asm.long_x("game_starts"))
            asm.beq("rt_start_lists")
            asm.tay
            asm.lda(asm.long_x("game_starts", 2))
            asm.sta(asm.abs_y(0))
            asm.lda(asm.long_x("game_starts", 4))
            asm.sta(asm.abs_y(2))
            asm.txa
            asm.clc
            asm.adc(6)
            asm.tax
            asm.bra("rt_start_next")
            asm.label("rt_start_lists")
            asm.jsl(asm.long("rt_lists_start"))
            asm.jsl(asm.long("rt_picture_start"))
            asm.sep(0x20)
            asm.lda(Console::SNESHardware::NMI_ON)
            asm.sta(asm.abs(Console::SNESHardware::NMITIMEN))
            asm.rep(0x20)
            asm.jml(asm.long("rt_buttons_from_power_on"))
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            asm.jml(asm.long(routine)) if routine
            asm.rtl unless routine
          end
        end
      end
    end
  end
end
