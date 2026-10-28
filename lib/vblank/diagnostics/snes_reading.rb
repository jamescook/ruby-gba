# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING SUPER NINTENDO CARTRIDGE CAN BE ASKED that only the Super
    # Nintendo's way of keeping things answers — the same questions an Advance reader answers its own
    # way (AdvanceReading).
    #
    # A Super Nintendo cartridge plays in bsnes (ruby-snes-emulator), not in libmgba, and the one
    # reader (Verifier) is written over libmgba's core, so it cannot play one yet: a Super Nintendo
    # cartridge is read back by the lowering's own run (IR::Backends::SNES::HeadlessRun), which
    # plays it in bsnes and compares it with the interpreter. Each question here says so.
    module SNESReading
      # Eight lists of sixteen colours for the backgrounds, then eight for the sprites.
      PALETTE = Verifier::PaletteLayout.new(half: 128, group: 16)

      # bsnes keeps a cartridge's battery-backed RAM in a .srm file of its own, nothing after it.
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x800, clock_bytes: 0)

      def passes = refuse_snes_reader!(:passes)
      def sprites(_name = nil) = refuse_snes_reader!(:sprites)

      private

      def watch_passes! = nil

      def refuse_snes_reader!(question)
        raise ArgumentError, "A Super Nintendo cartridge cannot be read back by the Verifier yet, so it cannot say " \
                             "#{question}. Play it with VBlank::IR::Backends::SNES::HeadlessRun instead."
      end
    end
  end
end
