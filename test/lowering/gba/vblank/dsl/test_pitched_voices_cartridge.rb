# frozen_string_literal: true

require "test_helper"

# Pitched voices on the Advance's cartridge: the voice's play position and its fixed-point
# step, read off the console in the emulator. A higher note playing out sooner, and the
# friendly error, are in
# test/all/vblank/dsl/test_pitched_voices.rb.
class TestPitchedVoicesCartridge < Minitest::Test
  # --- hardware: the console reads a pitched voice faster ---
  #
  # Two voices of the same sample play together — one at its recorded pitch, one an octave
  # up. After a few frames we read each voice's play position off the console: the octave-up
  # voice should have advanced through the sample about twice as far. We also read its
  # fixed-point step and check it's the octave ratio.
  def test_a_pitched_voice_steps_faster_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      tone = sample :tone, pcm: [40, -40] * 3000, rate: 8000, note: :C4 # 6000 samples, no wrap in 6 frames
      tone.play(loop: true)              # voice 0 — recorded pitch
      tone.play(loop: true, pitch: :C5)  # voice 1 — an octave up
      game_loop { wait_vblank }
    end
    b.finalize_program
    v = assert_emulator_loads_rom(assemble_rom(b.program, name: "PIT0"), frames: 6)
    base, high = v.voices

    assert_operator base.position, :>, 0, "the base voice advanced through its sample"
    ratio = high.position.to_f / base.position
    assert_operator ratio, :>, 1.7, "the octave-up voice advanced ~2x as far (#{high.position} vs #{base.position})"
    assert_operator ratio, :<, 2.3, "...and not more than ~2x (#{high.position} vs #{base.position})"

    # A step is how fast the recording is read, so it carries the pitch AND the resampling:
    # the mix runs at a rate the sound hardware can sustain (Console::SampleClock), which is
    # rarely the rate the recording was made at. The pitch on its own is the two steps' ratio.
    assert_in_delta 523.0 / 262, high.step.to_f / base.step, 0.01, "an octave apart, whatever the mix rate"
    expected = (523.0 / 262 * (8000.0 / v.sample_clock.rate) * GBA::Mixer::STEP_ONE).round
    assert_in_delta expected, high.step, 2, "the octave step is the C5/C4 ratio in 16.16"
  end
end
