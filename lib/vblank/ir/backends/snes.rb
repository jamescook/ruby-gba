# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # Raised when a program cannot be made into a Super Nintendo cartridge: it reaches something
        # the Super Nintendo cannot do, or something its build does not make yet, or it is too big
        # for the cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "snes/w65816"
require_relative "snes/gsu"
require_relative "snes/spc700"
require_relative "snes/linker"
require_relative "snes/memory"
require_relative "snes/samples"
require_relative "snes/dsp_writes"
require_relative "snes/music"
require_relative "snes/runtime"
require_relative "snes/art"
require_relative "snes/painted_art"
require_relative "snes/lowering/picture"
require_relative "snes/lowering/paint"
require_relative "snes/lowering/collision"
require_relative "snes/lowering/saving"
require_relative "snes/lowering/sound"
require_relative "snes/lowering"
require_relative "snes/headless_run"
require_relative "snes/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a SUPER NINTENDO cartridge: the same program every other backend runs, lowered
      # to the 65816, the console's 16-bit processor, and laid out in a LoROM cartridge.
      #
      # HOW IT IS MADE. SNES::Lowering walks the IR and emits 65816 machine code through the Ruby
      # assembler (SNES::W65816), as the Game Boy Color's lowering emits SM83, sharing only what
      # the IR itself says with the other lowerings. The runtime the code calls is written in
      # 65816 here, in Ruby.
      #
      # THE BOARD. A plain cartridge is ROM alone, with battery-backed RAM when the game saves, and
      # runs on a plain console. A game that names the Super FX 2 (`variants: { snes: :superfx }`)
      # gets that chip's board instead (Cartridge::SNESROM::SUPER_FX): the same 65816 code, read at
      # the slow speed, with the chip's registers and RAM beside it. The SA-1 and the MSU-1 are
      # not made.
      class SNES
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says: every
        # variable by the game's name (its address in work RAM), every list ([its 24-bit place, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, the program it was built
        # from, each entry of the interpreter's sound log by the number the cartridge's own log keeps
        # it as (empty for a game that makes no sound), what the DSP writes for those entries are
        # worked out with (DSPWrites::Voicing, Lowering::Sound#sound_voicing), and the game's
        # recordings by the number a place playing one keeps (Runtime::Recordings).
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines, :sound_entries,
                             :sound_voicing, :recording_names) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # One routine of the game's in the cartridge: the addresses its code takes, 24 bits each,
        # and what it is to the author.
        GameRoutine = Data.define(:addresses, :routine)

        # +program+ as a cartridge (Cartridge::SNESROM), carrying its Places.
        def build(program, title: "VBLANK")
          board = board_for(program)
          memory = Memory.new
          painted = Lowering::Paint.painted?(program)
          saves = SaveLayout.named_by?(program)
          refuse_save_on_chip_board!(board) if saves
          sound = Lowering::Sound.sounds?(program)
          songs = Lowering::Sound.songs?(program)
          follows_level = songs && Music.follows_level?(program)
          effects = IR::Tunes.effects(program).uniq.size
          samples = Lowering::Sound.samples?(program)
          Runtime.reserve(memory, painted: painted, chip: board.name == :super_fx, sound: sound, songs: songs,
                                  music_follows_level: follows_level, effects: effects, samples: samples)
          lowering = Lowering.new(program, memory: memory)
          game = lowering.sections + lowering.art_sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, frame_begins: lowering.frame_begins, painted: painted,
                                             board: board, saves: saves, sound: sound,
                                             sound_waves: lowering.sound_waves,
                                             music: (lowering.music_section if songs),
                                             music_level_at: (lowering.variables.fetch(IR::Tunes::LEVEL) if follows_level),
                                             effects: effects, recordings: lowering.sound_recordings,
                                             plays: (lowering.recordings_section if samples))
          linked = Linker.new(runtime + game, most_banks: board.most_banks).link
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, routines: routines,
                             sound_entries: lowering.sound_entries, sound_voicing: lowering.sound_voicing,
                             recording_names: lowering.recording_names)
          vectors = { reset: linked.address_of("rt_reset"), nmi: linked.address_of("rt_nmi"),
                      irq: linked.address_of("rt_irq"), brk: linked.address_of("rt_irq"),
                      cop: linked.address_of("rt_irq") }
          Cartridge::SNESROM.new(linked.banks, title: title, vectors: vectors.transform_values { |at| at & 0xFFFF },
                                               built: built, board: board,
                                               save_bytes: saves ? Runtime::Saving::SIZE : 0)
        end

        private

        # A board with a chip on it (a Super FX) has RAM that is the chip's: bsnes keeps all of it as
        # the save, and the painted screen takes most of it. The build does not keep a save there yet.
        def refuse_save_on_chip_board!(board)
          return if board.chip_ram_bytes.zero?

          raise LoweringError, "This game saves, and it is for a #{Console::SUPER_NINTENDO.title} with a chip on its " \
                               "cartridge. The build cannot keep a save on that cartridge yet. To fix this, remove the " \
                               "chip from variants: or from --variant, or build the game without saves for that console."
        end

        # The board +program+'s cartridge is laid out for (Cartridge::SNESROM::BOARDS): the one its
        # variant names (Console::Variant#build), or a plain one. A variant whose board is not made
        # yet is refused.
        def board_for(program)
          variant = program.variant && Console.for(:snes).variant(program.variant)
          return Cartridge::SNESROM::PLAIN unless variant

          Cartridge::SNESROM::BOARDS.fetch(variant.build[:board]) do
            raise LoweringError, "This game is for a #{Console::SUPER_NINTENDO.title} with #{variant.title}. The " \
                                 "build cannot make a cartridge with that chip yet. To fix this, remove the chip " \
                                 "from variants: or from --variant."
          end
        end
      end
    end
  end
end
