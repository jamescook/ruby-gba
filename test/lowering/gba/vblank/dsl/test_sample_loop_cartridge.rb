# frozen_string_literal: true

require "test_helper"

# Looping a sample on the Advance's own cartridge: the end-of-clip interrupt restarts the sound
# instead of stopping it, heard off the console's speaker in the emulator. What the surface does
# is in test/all/vblank/dsl/test_sample_loop.rb.
class TestSampleLoopCartridge < Minitest::Test
  # --- hardware: the loop really plays on the console ---
  #
  # A ~2-frame clip looped over 6 frames makes the end-of-clip interrupt fire and restart
  # the sound a few times, so this exercises the loop-restart path on real hardware (not
  # just that it boots) — if the restart wedged the interrupt dispatcher, the frames would
  # not advance and the audio would die.
  def test_a_looping_sample_plays_real_audio_on_the_console
    b = Builder.new
    wave = ([100] * 4 + [-100] * 4) * 32 # 256 samples ~ 2 frames at 8000 Hz
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      music = sample :music, pcm: wave, rate: 8000
      music.play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(GBA.new.lower(b.program), title: "LOOP")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.sound?, "a looping sample should keep the speaker going (energy #{v.audio_energy})"
  end
end
