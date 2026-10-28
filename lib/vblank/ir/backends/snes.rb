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
require_relative "snes/runtime/boot"
require_relative "snes/runtime/int32"

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
      end
    end
  end
end
