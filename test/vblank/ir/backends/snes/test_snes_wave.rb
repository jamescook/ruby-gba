# frozen_string_literal: true

require "test_helper"

# THE WAVE VOICE ON A SUPER NINTENDO. The Advance's third voice loops 32 steps of four bits that the
# game chooses, at one of five loudnesses, which it makes by keeping so many quarters of each step
# and dropping what does not divide; it never fades. The S-DSP plays recordings, so each waveform a
# game names, at each loudness it plays it, is a looped recording of those steps, held at a fixed
# level until stop_wave lets it go. The checked run holds the sound log and the DSP's registers to
# the interpreter's, as for a beep (test_snes_beep.rb).
class TestSNESWave < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  WAVE_VOICE = 2 << 4 # the Advance's third voice
  KEY_ON = 0x4C
  KEY_OFF = 0x5C

  TUNE = VBlank.game("TUNE", consoles: %i[gba snes]) do
    enable_sound
    n = var :n, 0
    game_loop do
      n.add! 1
      (n == 2).then { wave :triangle, :C4 }
      (n == 4).then { wave :sine, 440, volume: :half }
      (n == 6).then { stop_wave }
    end
  end

  # The log agreeing, and every DSP write it means arriving: what each write should be is held by
  # the tests below.
  def test_the_sound_log_agrees_and_every_dsp_write_arrives
    run = SNES::CheckedRun.new.run(TUNE.program(console: :snes), frames: 8)

    assert_equal %i[enabled wave wave stop_wave], run.audio.map(&:first)
  end

  # After `wave :square, 1000`, each register from fullsnes: a wave of 32 samples read at 1000 waves
  # a second is 32000 samples a second, pitch $1000; ADSR off (ADSR1 bit 7 nought) and a fixed gain
  # of $7F, the most there is, so it never fades; ENVX is then the gain itself.
  def test_a_wave_holds_its_voice_at_a_fixed_level
    dsp = played(:square, 1000)

    assert_equal [0x00, 0x10], [dsp.getbyte(WAVE_VOICE + 2), dsp.getbyte(WAVE_VOICE + 3)], "the pitch"
    assert_equal 0x00, dsp.getbyte(WAVE_VOICE + 5) & 0x80, "the gain, not the ADSR"
    assert_equal 0x7F, dsp.getbyte(WAVE_VOICE + 7), "a fixed gain at the top"
    assert_equal [120, 120], [dsp.getbyte(WAVE_VOICE), dsp.getbyte(WAVE_VOICE + 1)], "as loud as a beep at 15"
    assert_equal 1 << 2, dsp.getbyte(KEY_ON)
    assert_equal 0, dsp.getbyte(KEY_OFF) & (1 << 2), "not let go"
    assert_equal 0x7F, dsp.getbyte(WAVE_VOICE + 8), "the envelope held at the gain"
  end

  # stop_wave lets the voice go: its key-off bit, and the envelope falling to nought (fullsnes: "the
  # envelope will decrease by 8 every sample", a few dozen samples from the top).
  def test_stop_wave_lets_the_voice_go
    run = SNES::CheckedRun.new.run(TUNE.program(console: :snes), frames: 8)
    dsp = run.dsp_registers

    assert_equal 1 << 2, dsp.getbyte(KEY_OFF) & (1 << 2)
    assert_equal 0, dsp.getbyte(WAVE_VOICE + 8), "silent"
  end

  # A wave after stop_wave sounds again: a key-off holds until something clears it, and a key-on
  # under it plays nothing (fullsnes, "KON/KOFF Notes").
  def test_a_wave_after_stop_wave_sounds_again
    again = VBlank.game("AGAIN", consoles: %i[gba snes]) do
      enable_sound
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 1).then { wave :square, 440 }
        (n == 3).then { stop_wave }
        (n == 6).then { wave :square, 440 }
      end
    end
    dsp = SNES::CheckedRun.new.run(again.program(console: :snes), frames: 9).dsp_registers

    assert_equal 0x7F, dsp.getbyte(WAVE_VOICE + 8), "sounding again, held at the gain"
  end

  # A triangle at :quarter, worked by hand: its steps climb 0..15 and back (Audio::Sound.wavetable),
  # and a quarter keeps one quarter of each, dropping the rest: 0 to 3 is nought, 4 to 7 is one,
  # 8 to 11 two, 12 to 15 three. The recording holds those steps, a nibble each, less eight.
  def test_a_quiet_wave_is_recorded_as_the_advances_staircase
    quarter = [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]
    recording = SNES::Samples.wave(VBlank::Audio::Sound.wavetable(:triangle).map { |step| step / 4 })

    assert_equal quarter + quarter.reverse, nibbles(recording).map { |nibble| nibble + 8 }
  end

  private def played(shape, frequency)
    game = VBlank.game("WAVE", consoles: %i[gba snes]) do
      enable_sound
      wave shape, frequency
      n = var :n, 0
      game_loop { n.add! 1 }
    end
    SNES::CheckedRun.new.run(game.program(console: :snes), frames: 3).dsp_registers
  end

  # Each sample of a BRR recording as a signed nibble, after a header byte every nine (fullsnes).
  private def nibbles(bytes)
    bytes.each_slice(9).flat_map do |block|
      block.drop(1).flat_map { |byte| [byte >> 4, byte & 0xF] }.map { |nibble| nibble >= 8 ? nibble - 16 : nibble }
    end
  end
end
