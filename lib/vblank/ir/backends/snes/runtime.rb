# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/paint"
require_relative "runtime/tint"
require_relative "runtime/collide"
require_relative "runtime/chip"
require_relative "runtime/chip_paint"
require_relative "runtime/saving"
require_relative "runtime/sound"
require_relative "runtime/music"

module VBlank
  module IR
    module Backends
      class SNES
        # THE RUNTIME every Super Nintendo cartridge carries: from power-on to the game's first line
        # (Boot), the arithmetic (Int32), the frame and the buttons (Frame), the lists (Lists), the
        # picture (Picture), and save memory (Saving) for a game that saves.
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
          # +painted+ (Paint) keeps its copy of the screen in work RAM's last bank. A cartridge with a
          # Super FX (+chip+) keeps the chip's waiting loop and its counts (Chip), after the rest so
          # a plain cartridge's places do not move. A game with +songs+ keeps their player's places
          # (Music), and those of the music volume if it sets one (+music_follows_level+).
          def reserve(memory, painted: false, chip: false, sound: false, songs: false, music_follows_level: false)
            Paint.reserve(memory, chip: chip) if painted
            Frame.reserve(memory)
            Picture.reserve(memory)
            Tint.reserve(memory)
            Chip.reserve(memory) if chip
            Sound.reserve(memory) if sound
            Music.reserve(memory, follows_level: music_follows_level) if songs
          end

          # The runtime's sections: the entry points in the first bank, and everything else in one.
          # +main+ is the label of the game's main routine; +frame_begins+ the label of the game's
          # routine run at each frame boundary (its timers moving on), or nil for none; +painted+
          # for a game whose screen is painted rather than drawn from tiles; +board+ the cartridge's
          # board (Cartridge::SNESROM::BOARDS); +saves+ for a game that reaches save memory, whose
          # routines a game that does not is made without, so its cartridge is the same bytes; +sound+
          # for a game that makes sound, which sends the sound unit its program at power-on, with
          # +sound_waves+, the wave voice's waveforms, recorded beside it; +music+ the section of its
          # songs (SNES::Music#section), for a game with songs, whose player (Music) it then carries;
          # +music_level_at+ where such a game keeps its music volume, if it sets one.
          def sections(memory, main:, frame_begins: nil, painted: false, board: Cartridge::SNESROM::PLAIN, saves: false,
                       sound: false, sound_waves: [], music: nil, music_level_at: nil)
            chip = board.name == :super_fx
            vectors = W65816.new("runtime vectors", home: :first)
            Boot.emit_vectors(vectors)
            asm = W65816.new("runtime")
            Boot.emit(asm, main: main, fast: board.fast)
            Boot.emit_zero(asm)
            Int32.emit(asm, Int32.scratch(memory))
            Frame.emit(asm, memory, pad: memory.scratch(4), sound: sound)
            Lists.emit(asm, memory, Lists.scratch(memory))
            Picture.emit(asm, memory, work: memory.scratch(8), painted: painted, chip: chip)
            Paint.emit(asm, memory, Paint.scratch(memory), chip: chip) if painted
            Tint.emit(asm, memory, Tint.scratch(memory))
            Collide.emit(asm, memory, Collide.scratch(memory))
            Chip.emit(asm, memory) if chip
            Saving.emit(asm, memory, Saving.scratch(memory)) if saves
            Sound.emit(asm, memory, sound_waves, songs: !music.nil?) if sound
            Music.emit(asm, memory, level_at: music_level_at) if music
            emit_start(asm, chip: chip, sound: sound)
            emit_frame_begins(asm, frame_begins)
            [vectors.section, asm.section] + (chip && painted ? [ChipPaint.gsu_section] : []) +
              (sound ? Sound.sections(sound_waves) : []) + (music ? [music] : [])
          end

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place as a word and its number as two, and a place of nought
          # after the last), its lists' headers, the picture's start, the screen's interrupt
          # switched on, and the buttons held from power-on. A game that makes sound sends the sound
          # unit its program first, while the screen's interrupt is still off (Sound).
          def emit_start(asm, chip: false, sound: false)
            asm.label("rt_start")
            asm.jsl(asm.long("rt_chip_start")) if chip
            asm.jsl(asm.long("rt_sound_start")) if sound
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
