# frozen_string_literal: true

require "test_helper"

# The sound unit's own program, sent across at power-on (Runtime::Sound's rt_sound_start), and the
# console telling it what to write into the S-DSP's registers (rt_sound_write). What the DSP holds
# is read straight from the emulator, so these are the sound unit's own registers, not anything the
# runtime says about them.
class TestSNESSoundDriver < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Sound = SNES::Runtime::Sound
  DONE = 0x1F00 # where the console marks that it got to the end

  # The S-DSP's main volume, left and right, and voice n's left volume ($n0).
  MAIN_LEFT = 0x0C
  MAIN_RIGHT = 0x1C

  def test_the_program_is_sent_and_each_write_reaches_the_dsp
    memory = new_memory
    writes = [[MAIN_LEFT, 0x5A], [MAIN_RIGHT, 0x3C]] + (0..7).map { |voice| [voice << 4, (voice * 3) + 1] }
    core_after(cartridge(memory, writes)) do |core|
      dsp = core.dsp_registers

      assert_equal 0x5A, dsp.getbyte(MAIN_LEFT)
      assert_equal 0x3C, dsp.getbyte(MAIN_RIGHT)
      assert_equal (0..7).map { |voice| (voice * 3) + 1 }, (0..7).map { |voice| dsp.getbyte(voice << 4) }
      assert_equal Sound.driver.assembled, core.apu_ram.byteslice(Sound::DRIVER_AT, Sound.driver.assembled.bytesize)
      assert_equal 0, core.wram_read16(memory[Sound::DROPPED]), "no write was dropped"
      assert_equal 0xC3, core.wram.getbyte(DONE)
    end
  end

  # One after another as fast as the console can send them, and the sound unit keeps up.
  def test_two_hundred_writes_in_a_row_are_all_taken
    memory = new_memory
    writes = Array.new(200) { |n| [MAIN_LEFT, n & 0x7F] }
    core_after(cartridge(memory, writes)) do |core|
      assert_equal 0, core.wram_read16(memory[Sound::DROPPED])
      assert_equal 199 & 0x7F, core.dsp_registers.getbyte(MAIN_LEFT), "the last write is the one that stays"
    end
  end

  # A sound unit that never answers costs each write a short wait, then the write is dropped and
  # counted: a frame is never lost to sound.
  def test_a_sound_unit_that_never_answers_drops_each_write_and_the_game_goes_on
    memory = new_memory
    writes = Array.new(20) { [MAIN_LEFT, 0x7F] }
    core_after(cartridge(memory, writes, send_program: false), frames: 2) do |core|
      assert_equal 0xC3, core.wram.getbyte(DONE), "the console got to the end within two frames"
      assert_equal 20, core.wram_read16(memory[Sound::DROPPED])
      refute_equal 0x7F, core.dsp_registers.getbyte(MAIN_LEFT)
    end
  end

  private def new_memory
    memory = SNES::Memory.new
    Sound.reserve(memory)
    memory
  end

  private def core_after(rom, frames: 10)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sound.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      frames.times { core.run_frame }
      yield core
    ensure
      core&.destroy
    end
  end

  # A cartridge whose reset sets the console up as the runtime's boot does, sends the sound unit its
  # program (or, without +send_program+, says it did, so every write waits on a sound unit that never
  # answers), makes each of +writes+ ([register, value]) and marks DONE.
  private def cartridge(memory, writes, send_program: true)
    runtime = SNES::W65816.new("runtime")
    Sound.emit(runtime, memory)
    test = self
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
      if send_program
        jsl long("rt_sound_start")
      else
        lda 1
        sta abs(memory[Sound::LIVE])
        lda 0x77 # a number the built-in program never puts in mailbox 0 (it holds 0, then $AA)
        sta abs(memory[Sound::SENT])
      end
      writes.each do |register, value|
        lda register
        sta direct(SNES::Memory.register(0))
        lda value
        sta direct(SNES::Memory.register(1))
        jsl long("rt_sound_write")
      end
      sep 0x20
      lda 0xC3
      sta abs(test.class::DONE)
      label "forever"
      bra "forever"
      label "interrupted"
      rti
    end

    linked = SNES::Linker.new([boot.section, runtime.section, *Sound.sections]).link
    vectors = { reset: linked.address_of("reset"), nmi: linked.address_of("interrupted"),
                irq: linked.address_of("interrupted") }
    VBlank::Cartridge::SNESROM.new(linked.banks, title: "SOUND", vectors: vectors.transform_values { |at| at & 0xFFFF })
  end
end
