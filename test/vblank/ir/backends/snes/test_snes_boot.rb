# frozen_string_literal: true

require "test_helper"

# A cartridge made of the assembler's code, the Linker's banks and SNESROM's header plays in the
# emulator: the processor starts at the reset vector, goes to the fast copy of the cartridge, and
# what it writes to the colour memory is the picture.
class TestSNESBoot < Minitest::Test
  W65816 = VBlank::IR::Backends::SNES::W65816
  Linker = VBlank::IR::Backends::SNES::Linker
  H = VBlank::Console::SNESHardware

  private def cartridge(colour)
    asm = W65816.new("boot", home: :first)
    asm.instance_eval do
      label "reset"
      sei
      clc
      xce # native mode
      jml long("fast")
      label "fast" # now running from bank $80, the fast copy
      sep 0x20
      lda 0x80
      sta abs(H::INIDISP)
      stz abs(H::CGADD)
      lda colour & 0xFF
      sta abs(H::CGDATA)
      lda colour >> 8
      sta abs(H::CGDATA)
      lda 0x0F
      sta abs(H::INIDISP)
      label "forever"
      bra "forever"
    end
    linked = Linker.new([asm.section]).link
    VBlank::Cartridge::SNESROM.new(linked.banks, title: "BOOT", vectors: { reset: linked.address_of("reset") & 0xFFFF })
  end

  private def picture_of(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "boot.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      3.times { core.run_frame }
      [core.colors.uniq, core.registers.fetch(:pc) >> 16]
    ensure
      core&.destroy
    end
  end

  def test_the_backdrop_is_the_colour_the_cartridge_wrote
    green = 0x03E0
    colours, bank = picture_of(cartridge(green))
    assert_equal [green], colours
    assert_equal 0x80, bank, "the processor runs from the fast copy of the cartridge"
  end
end
