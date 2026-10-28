# frozen_string_literal: true

require "test_helper"

# A NOISE HIT ON A SUPER NINTENDO. The Advance's noise voice steps a random-bit register at a clock
# of its own: fifteen bits for a hiss that never seems to repeat, seven for a "metallic" rattle
# that comes round every 127 steps. The S-DSP has one noise generator of the first kind, its clock
# kept in FLG's low five bits beside the mute and reset switches; it has none of the second, which
# is played as a looped recording of that 127-step pattern. The checked run holds the sound log and
# the DSP's registers to the interpreter's, as for a beep (test_snes_beep.rb).
class TestSNESNoise < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  NOISE_VOICE = 3 << 4 # the Advance's fourth voice is its noise voice
  NON = 0x3D
  FLG = 0x6C

  HITS = VBlank.game("HITS", consoles: %i[gba snes]) do
    enable_sound
    n = var :n, 0
    game_loop do
      n.add! 1
      (n == 2).then { noise :hit }
      (n == 4).then { noise :hat }
      (n == 5).then { noise :explosion }
    end
  end

  def test_the_sound_log_and_the_dsp_agree_with_the_interpreter
    run = SNES::CheckedRun.new.run(HITS.program(console: :snes), frames: 6)

    assert_equal %i[mid high low], run.audio.drop(1).map { |entry| entry.last[:pitch] }
  end

  # The registers after a plain hiss at :mid, each from fullsnes: the Advance clocks a :mid hiss at
  # 524288 * 2 / 2^6 = 16384 Hz, and the nearest of the DSP's noise rates is $1E, 16000 Hz.
  def test_a_hiss_runs_the_dsp_noise_generator_on_the_noise_voice
    dsp = played(pitch: :mid, decay: :none, volume: 10, metallic: false)

    assert_equal 1 << 3, dsp.getbyte(NON), "the noise voice plays the noise generator"
    assert_equal 0x20 | 0x1E, dsp.getbyte(FLG), "sound on, and the noise clock at 16000 Hz"
    assert_equal [80, 80], [dsp.getbyte(NOISE_VOICE), dsp.getbyte(NOISE_VOICE + 1)], "volume 10, left and right"
    assert_operator dsp.getbyte(NOISE_VOICE + 8), :>=, 0x70, "held at the top: the voice is sounding"
  end

  # A metallic rattle is a recording, read one sample for each of the Advance's steps: a :high one
  # steps 524288 * 2 / 2^3 = 131072 times a second, faster than the pitch register can read
  # ($3FFF, near 128000 samples a second), so it plays at the fastest there is.
  def test_a_metallic_rattle_plays_its_recording_and_not_the_noise_generator
    dsp = played(pitch: :high, decay: :none, volume: 8, metallic: true)

    assert_equal 0, dsp.getbyte(NON) & (1 << 3), "not the noise generator"
    assert_equal [0xFF, 0x3F], [dsp.getbyte(NOISE_VOICE + 2), dsp.getbyte(NOISE_VOICE + 3)], "the fastest pitch"
    assert_equal SNES::Samples::METALLIC, dsp.getbyte(NOISE_VOICE + 4)
    assert_operator dsp.getbyte(NOISE_VOICE + 8), :>=, 0x70, "the voice is sounding"
  end

  # The pattern the recording holds, worked out the Advance's way (GBATEK, "GBA Sound Channel 4"):
  # X = X SHR 1, and if a 1 fell out the output is high and X = X XOR $60, from X = $40.
  def test_the_metallic_recording_is_the_advances_seven_bit_pattern_and_repeats_every_127
    x = 0x40
    pattern = Array.new(127) do
      carry = x & 1
      x >>= 1
      x ^= 0x60 if carry == 1
      carry
    end

    decoded = brr_signs(SNES::Samples.metallic)
    assert_equal 127 * 16, decoded.size, "sixteen times round fills whole blocks"
    assert_equal pattern * 16, decoded
  end

  # A program built by hand can make noise before enable_sound: the noise clock is set, and the
  # sound unit stays muted and held off.
  def test_noise_before_enable_sound_sets_the_clock_and_leaves_the_sound_unit_muted
    build = VBlank::IR::Build
    run = SNES::CheckedRun.new.run(build.program(build.loop_(build.noise(:kick), build.wait_vblank)), frames: 3)

    assert_equal 0xE0, run.dsp_registers.getbyte(FLG) & 0xE0
    refute_equal 0, run.dsp_registers.getbyte(FLG) & 0x1F, "the clock is set all the same"
  end

  private def played(**hit)
    game = VBlank.game("HIT", consoles: %i[gba snes]) do
      enable_sound
      game_loop { noise(**hit) }
    end
    SNES::CheckedRun.new.run(game.program(console: :snes), frames: 2).dsp_registers
  end

  # Each sample of a BRR recording as 1 (above nought) or 0, from its nibbles: the format is
  # fullsnes's, the high nibble of each byte first, after a header byte every nine.
  private def brr_signs(bytes)
    bytes.each_slice(9).flat_map do |block|
      block.drop(1).flat_map { |byte| [byte >> 4, byte & 0xF] }.map { |nibble| nibble < 8 && nibble.positive? ? 1 : 0 }
    end
  end
end
