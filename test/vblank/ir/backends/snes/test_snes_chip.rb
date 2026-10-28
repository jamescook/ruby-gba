# frozen_string_literal: true

require "test_helper"

# The two processors of a Super FX cartridge working together: the console hands the chip a
# program (Runtime::Chip's rt_chip_run), the chip runs it from the cartridge's ROM and writes into
# its own RAM, stops, and the console carries on from work RAM and then from the cartridge again.
class TestSNESChip < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  H = VBlank::Console::SNESHardware
  DONE = 0x1F00 # where the console marks that it came back from the chip

  def test_the_chip_runs_a_program_and_the_console_reads_what_it_wrote
    ram, wram = played(cartridge)

    assert_equal 0x5A, ram.getbyte(0), "the chip's STB wrote its byte"
    assert_equal 0x1234 * 3, ram.byteslice(2, 2).unpack1("v"), "the chip's sum, written as a word"
    assert_equal 0xC3, wram.getbyte(DONE), "the console came back to the cartridge after the chip stopped"
  end

  # While the chip runs the vertical blank's interrupt is off, and the waiting loop counts the blanks
  # instead: once each, however many go by.
  def test_the_frames_the_chip_took_are_counted_once_each
    memory = new_memory
    rom = cartridge(memory) do
      iwt 4, 8
      label "outer"
      iwt 12, 0xFFFF
      iwt 13, "inner"
      label "inner"
      loop              # round 65535 times, from the ROM
      nop
      dec 4
      bne "outer"
      nop
      stop
    end
    frames, counted = frames_until_done(rom, memory)

    assert_operator frames, :>, 5, "the chip ran for several frames"
    assert_in_delta frames, counted, 2, "the frames the runtime counted"
  end

  private def new_memory
    memory = SNES::Memory.new
    SNES::Runtime::Frame.reserve(memory)
    SNES::Runtime::Chip.reserve(memory)
    memory
  end

  # The frames played until the console marked DONE, and the frame count the runtime kept.
  private def frames_until_done(rom, memory)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chip.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      frames = (1..120).find do
        core.run_frame
        core.wram.getbyte(DONE) == 0xC3
      end
      [frames, core.wram_read32(memory[SNES::Runtime::Frame::FRAMES])]
    ensure
      core&.destroy
    end
  end

  # A cartridge whose reset sets the console up as the runtime's boot does, runs the chip once and
  # marks DONE. The chip's program is the block, or one that writes two numbers into its RAM.
  private def cartridge(memory = new_memory, &program)
    program ||= proc do
      ibt 0, 0x5A
      iwt 1, 0x0000
      stb 1             # RAM $0000 = $5A
      iwt 3, 0x1234
      iwt 0, 0x1234
      add 3
      add 3             # R0 = 3 × $1234
      iwt 1, 0x0002
      stw 1             # RAM $0002 = R0, low byte first
      stop
    end
    runtime = SNES::W65816.new("runtime")
    SNES::Runtime::Chip.emit(runtime, memory)

    boot = SNES::W65816.new("boot", home: :first)
    boot.instance_eval do
      label "reset"
      sei
      clc
      xce
      rep 0x30
      lda SNES::Memory::STACK_TOP
      tcs
      lda 0
      tcd
      sep 0x20
      lda 0x80
      pha
      plb
      rep 0x20
      jsl long("rt_chip_start")
      lda imm("chip program")
      sta direct(0)
      lda bank_of("chip program")
      sta direct(2) # the bank, and nought for the picture's layout
      jsl long("rt_chip_run")
      sep 0x20
      lda 0xC3
      sta abs(DONE)
      label "forever"
      bra "forever"
      label "interrupted"
      rti
    end

    gsu = SNES::GSU.new("chip")
    gsu.label "chip program"
    gsu.instance_eval(&program)

    linked = SNES::Linker.new([boot.section, runtime.section, gsu.section]).link
    vectors = { reset: linked.address_of("reset"), nmi: linked.address_of("interrupted"),
                irq: linked.address_of("interrupted") }
    VBlank::Cartridge::SNESROM.new(linked.banks, title: "CHIP", vectors: vectors.transform_values { |at| at & 0xFFFF },
                                                 board: VBlank::Cartridge::SNESROM::SUPER_FX)
  end

  private def played(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chip.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      5.times { core.run_frame }
      [core.save_ram, core.wram]
    ensure
      core&.destroy
    end
  end
end
