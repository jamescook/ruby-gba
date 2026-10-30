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

  # A vertical blank sets a flag as it begins (RDNMI's top bit), and switching the blank's
  # interrupt on while that flag is set calls the interrupt at once (fullsnes, "SNES I/O Map",
  # NMITIMEN). So a setting up that ends inside a blank would count that blank, half gone, as a
  # frame shown. The cartridge switches the interrupt on the runtime's way from inside a blank
  # and counts the interrupts until that blank is over: none.
  def test_the_interrupt_switched_on_inside_a_blank_waits_for_the_next
    calls = Dir.mktmpdir do |dir|
      path = File.join(dir, "blank.sfc")
      interrupt_counting_cartridge.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      3.times { core.run_frame }
      core.wram_read8(SEEN_INSIDE)
    ensure
      core&.destroy
    end

    assert_equal 0, calls
  end

  COUNT = 0x0010 # the interrupts so far
  SEEN_INSIDE = 0x0012 # the count as the blank the interrupt was switched on in ended

  private def interrupt_counting_cartridge
    asm = W65816.new("blank", home: :first)
    asm.instance_eval do
      label "reset"
      sei
      clc
      xce
      jml long("fast")
      label "fast"
      rep 0x30
      lda 0x1FFF
      tcs
      sep 0x20
      stz abs(COUNT)
      lda 0xFF
      sta abs(SEEN_INSIDE)
      # Into the next blank's middle: out of any blank, then in one.
      label "out_of_blank"
      lda abs(H::HVBJOY)
      bmi "out_of_blank"
      label "into_blank"
      lda abs(H::HVBJOY)
      bpl "into_blank"
      rep 0x20
    end
    VBlank::IR::Backends::SNES::Runtime.emit_interrupt_on(asm)
    asm.instance_eval do
      sep 0x20
      label "inside_blank"
      lda abs(H::HVBJOY)
      bmi "inside_blank"
      lda abs(COUNT)
      sta abs(SEEN_INSIDE)
      label "forever"
      bra "forever"
      label "interrupt"
      sep 0x20
      inc abs(COUNT)
      lda abs(H::RDNMI)
      rti
    end
    linked = Linker.new([asm.section]).link
    VBlank::Cartridge::SNESROM.new(linked.banks, title: "BLANK",
                                                 vectors: { reset: linked.address_of("reset") & 0xFFFF,
                                                            nmi: linked.address_of("interrupt") & 0xFFFF })
  end
end
