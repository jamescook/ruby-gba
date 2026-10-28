# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN ON A SUPER FX CARTRIDGE: what Paint does differently there.
          #
          # The picture is kept where Paint keeps it, laid out the same way (896 tiles of eight bits a
          # pixel, in the order they are shown), but in the Super FX's own RAM, $70:0000 to $70:DFFF,
          # rather than the last bank of work RAM. The console's processor can read and write that RAM
          # whenever the chip is stopped, so every one of Paint's routines paints there unchanged.
          # What Paint keeps beside the copy (each tile's generation, the map, the runs to send) is
          # in work RAM with the game's far places.
          #
          # A clear writes nothing on either cartridge (Paint moves the screen on a generation), so
          # the chip has nothing of the clear to do. The copy to video RAM is Paint's
          # rt_paint_upload, a blank at a time with the screen on, from the chip's RAM rather than
          # work RAM.
          module ChipPaint
            COPY = Console::SNESHardware::GSU_RAM_BANK << 16
          end
        end
      end
    end
  end
end
