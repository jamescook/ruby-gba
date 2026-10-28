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
require_relative "snes/linker"
require_relative "snes/memory"
require_relative "snes/runtime"
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
      # NO CARTRIDGE CHIPS. The cartridge is ROM alone, with battery-backed RAM when the game
      # saves, and runs on a plain console. The Super FX, the SA-1 and the MSU-1 are not used;
      # a cartridge that wanted one would say so in its header (Cartridge::SNESROM's map mode and
      # cartridge type) and be laid out for it in the Linker.
      class SNES
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says: every
        # variable by the game's name (its address in work RAM), every list ([its 24-bit place, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, and the program it was
        # built from.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # One routine of the game's in the cartridge: the addresses its code takes, 24 bits each,
        # and what it is to the author.
        GameRoutine = Data.define(:addresses, :routine)

        # +program+ as a cartridge (Cartridge::SNESROM), carrying its Places.
        def build(program, title: "VBLANK")
          memory = Memory.new
          Runtime.reserve(memory)
          lowering = Lowering.new(program, memory: memory)
          game = lowering.sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, frame_begins: lowering.frame_begins)
          linked = Linker.new(runtime + game).link
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, routines: routines)
          vectors = { reset: linked.address_of("rt_reset"), nmi: linked.address_of("rt_nmi"),
                      irq: linked.address_of("rt_irq"), brk: linked.address_of("rt_irq"),
                      cop: linked.address_of("rt_irq") }
          Cartridge::SNESROM.new(linked.banks, title: title, vectors: vectors.transform_values { |at| at & 0xFFFF },
                                               built: built)
        end
      end
    end
  end
end
