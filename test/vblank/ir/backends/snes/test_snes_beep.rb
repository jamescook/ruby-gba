# frozen_string_literal: true

require "test_helper"

# A BEEP ON A SUPER NINTENDO: the sound unit's S-DSP told, through the program the console sends it
# at power-on (Runtime::Sound), which looped square recording to play on the beep's voice, at what
# pitch, how loud and how fast to fade. The checked run holds the cartridge's sound log to the
# interpreter's, and the DSP's own registers, read from the emulator after every pass, to what that
# log says they must hold.
class TestSNESBeep < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  BEEPING = VBlank.game("BEEPS", consoles: %i[gba snes]) do
    enable_sound
    n = var :n, 0
    define_sound :ping, frequency: 440, duty: :quarter, decay: :slow, volume: 9
    game_loop do
      n.add! 1
      (n == 2).then { beep :high }
      (n == 4).then { beep :ping }
      (n == 5).then { beep 1000, duty: :eighth, decay: :none }
    end
  end

  def test_the_sound_log_and_the_dsp_agree_with_the_interpreter
    run = SNES::CheckedRun.new.run(BEEPING.program(console: :snes), frames: 6)

    effects = run.audio.drop(1).map(&:last)
    assert_equal [:enabled], run.audio.first
    assert_equal [880, 440, 1000], effects.map(&:frequency)
  end

  # The registers of the beep's voice after `beep 1000, duty: :eighth, decay: :none`, each worked
  # out from fullsnes rather than from the lowering: pitch $1000 plays 32000 samples a second, and a
  # square recording is 32 samples a wave, so 1000 Hz is 1000 * 32 * $1000 / 32000 = 4096 = $1000.
  def test_a_beep_sets_its_voices_registers_as_fullsnes_says
    dsp = SNES::HeadlessRun.new.run(BEEPING.program(console: :snes), frames: 6).dsp_registers
    voice = SNES::DSPWrites::BEEP_VOICE << 4

    assert_equal [0x00, 0x10], [dsp.getbyte(voice + 2), dsp.getbyte(voice + 3)], "the pitch, low byte first"
    assert_equal 0, dsp.getbyte(voice + 4), "the first recording, the eighth-wide square of 32 samples a wave"
    assert_equal [15 * 8, 15 * 8], [dsp.getbyte(voice), dsp.getbyte(voice + 1)], "volume 15, left and right"
    assert_equal 0x8F, dsp.getbyte(voice + 5), "ADSR on, the fastest attack"
    assert_equal 0xE0, dsp.getbyte(voice + 6), "no fade: a sustain rate of nought holds"
    assert_equal 1 << SNES::DSPWrites::BEEP_VOICE, dsp.getbyte(0x4C), "keyed on"
    assert_equal 0x20, dsp.getbyte(0x6C), "sound on: not muted, not reset, echo writes off"
    # ENVX ($x8), the envelope where it is now: a note that never fades sits at the top, which it
    # only reaches by playing the recording the sample table points it at.
    assert_operator dsp.getbyte(voice + 8), :>=, 0x70, "the voice is sounding, held at the top"
  end

  # A note too high for a wave of 32 samples (the pitch register's most, $3FFF, reads one near 4000
  # Hz) plays on the recording of 8 samples a wave: 8000 Hz is 8000 * 8 * $1000 / 32000 = $2000.
  def test_a_high_beep_plays_on_the_short_wave
    high = VBlank.game("HIGH", consoles: %i[gba snes]) do
      enable_sound
      game_loop { beep 8000, duty: :half }
    end
    run = SNES::CheckedRun.new.run(high.program(console: :snes), frames: 2)
    dsp = run.dsp_registers
    voice = SNES::DSPWrites::BEEP_VOICE << 4

    assert_equal [0x00, 0x20], [dsp.getbyte(voice + 2), dsp.getbyte(voice + 3)]
    assert_equal 4 + 2, dsp.getbyte(voice + 4), "after the four long recordings, the short half-wide one"
  end

  # HOW LONG A BEEP TAKES TO FADE, held to the Advance's rule rather than to the lowering's table:
  # its volume fades a step every 1, 3 or 5 64ths of a second (fast, medium, slow), so volume v is
  # gone in v * step / 64 seconds, v * step * 60 / 64 frames. On the Super Nintendo the envelope is
  # read back from the DSP itself (ENVX, $x8: its top seven bits), and the note counts as gone once
  # ENVX reads nought.
  def test_a_beep_fades_in_about_the_advances_time_for_its_volume_and_speed
    [[15, :fast, 1], [15, :slow, 5], [6, :medium, 3], [3, :fast, 1]].each do |volume, decay, step|
      frames = frames_to_fade(volume, decay)
      expected = volume * step * 60 / 64.0

      assert_in_delta expected, frames, [expected * 0.3, 3].max, "volume #{volume} fading #{decay}"
    end
  end

  private def frames_to_fade(volume, decay)
    game = VBlank.game("FADE", consoles: %i[gba snes]) do
      enable_sound
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 1).then { beep 440, volume: volume, decay: decay }
      end
    end
    run = SNES::HeadlessRun.new.run(game.program(console: :snes), frames: 100)
    envelope = run.dsp_moments.map { |dsp| dsp.getbyte((SNES::DSPWrites::BEEP_VOICE << 4) + 8) }
    sounding = envelope.index(&:positive?)
    sounding && (envelope.drop(sounding).index(&:zero?) || envelope.size)
  end

  # The DSL refuses a beep before enable_sound; a program built by hand can still reach one.
  def test_a_beep_before_enable_sound_leaves_the_sound_unit_muted
    build = VBlank::IR::Build
    quiet = build.program(build.loop_(build.beep(:blip), build.wait_vblank))
    run = SNES::CheckedRun.new.run(quiet, frames: 3)

    assert_equal 0xE0, run.dsp_registers.getbyte(0x6C) & 0xE0, "still muted and held off, as at power-on"
  end
end
