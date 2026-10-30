# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/ir/backends/reference/test_mixer_on_the_advance"

# THE MIXER ON THE ADVANCE'S CARTRIDGE: the voices its own table holds, and the mix read straight
# out of its buffers in the emulator. The mixer as every run plays it is in
# test/all/vblank/ir/backends/reference/test_mixer.rb, and as every run of an Advance game plays
# it in test/console/gba/vblank/ir/backends/reference/test_mixer_on_the_advance.rb.
class TestMixerCartridge < Minitest::Test
  include MixerGames

  # TWO MORE DIFFERENT SOUNDS THAN THE MIXER HAS VOICES (MixerGames::SOUNDS), asked of the
  # cartridge by name: its own voice table says what the lowering really did.
  def test_both_backends_keep_the_same_sounds_when_the_mixer_is_full
    kept = SOUNDS.first(VBlank::Audio::Sound::MIXER_VOICES)
    console = assert_emulator_loads_rom(assemble_rom(sounds_past_the_mixer), frames: 6).sounding

    assert_equal kept, console, "the console keeps the first #{kept.size} and drops the rest"
  end

  def test_a_program_that_plays_no_samples_has_no_voices
    silent = frames_program(2) { sample :unused, pcm: [10, -10] * 100, rate: 8000 }
    assert_empty assert_emulator_loads_rom(assemble_rom(silent), frames: 3).voices
  end

  # A cartridge assembled without its build record cannot say where its voices are. That is a
  # mistake in how the test was set up, not a fact about the sound, so it says how to fix it
  # rather than failing on a nil somewhere inside.
  def test_a_rom_without_its_build_record_says_how_to_attach_one
    program = frames_program(2) { sample(:zap, pcm: [10, -10] * 100, rate: 8000).play }
    bare = ROM.assemble(GBA.new.lower(program), title: "BARE", code: "BBAR", maker: "01")

    error = assert_raises(ArgumentError) { VBlank::Diagnostics::Verifier.new(bare, frames: 1).voices }
    assert_match(/build record/, error.message)
  end

  # --- hardware: the console really sums the voices ---
  #
  # Two constant-valued samples play at once; the mixer adds them into its output buffer,
  # which we read straight off the console. Every byte should be the SUM (not the last voice
  # to play, which would prove nothing was mixed).
  def test_two_voices_are_summed_on_the_console
    quiet, loud = 20, 30
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = sample :a, pcm: [quiet] * 400, rate: 8000 # steady levels so the sum is the same everywhere
      c = sample :c, pcm: [loud] * 400, rate: 8000
      a.play(loop: true)
      c.play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "MIX0", code: "BMIX", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert v.sound?, "the mix should be audible (energy #{v.audio_energy})"
    assert mixed.all?(quiet + loud), "both voices summed to #{quiet + loud}, but the buffer held #{mixed.inspect}"
  end

  # The saturating clamp: two loud voices that would sum past the 8-bit ceiling are
  # pinned at +127, not wrapped to a negative (which would be a harsh click). This
  # exercises the branchless (predicated) clamp on the hot mix path.
  def test_the_mix_saturates_at_the_ceiling
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = sample :a, pcm: [100] * 400, rate: 8000 # 100 + 100 = 200, past +127
      c = sample :c, pcm: [100] * 400, rate: 8000
      a.play(loop: true)
      c.play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "MIXH", code: "BMXH", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(127), "200 should saturate to +127, but the buffer held #{mixed.inspect}"
  end

  # ...and the floor: two very negative voices pin at -128, not wrap to a positive.
  def test_the_mix_saturates_at_the_floor
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = sample :a, pcm: [-100] * 400, rate: 8000 # -100 + -100 = -200, past -128
      c = sample :c, pcm: [-100] * 400, rate: 8000
      a.play(loop: true)
      c.play(loop: true)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "MIXL", code: "BMXL", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(-128), "-200 should saturate to -128, but the buffer held #{mixed.inspect}"
  end

  # THE CLAMP IS ON THE FINISHED SUM, not on each voice as it is added, so a loud voice and a
  # loud voice of the other sign cancel whatever order they arrive in: 100 + 100 - 100 is 100.
  # Clamped as each voice went in, the first two would pin at 127 and the third take it to 27.
  def test_the_mix_clamps_the_sum_not_each_voice
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      [100, 100, -100].each_with_index { |level, n| sample(:"v#{n}", pcm: [level] * 400, rate: 8000).play(loop: true) }
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "MIXS", code: "BMXS", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(100), "100 + 100 - 100 should mix to 100, but the buffer held #{mixed.inspect}"
  end

  # A frame with nothing sounding is written as silence — every byte of both buffers, however
  # loud the last sound was — rather than left holding the last slice, which would buzz.
  def test_once_every_sound_has_finished_both_buffers_are_silent
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      sample(:bang, pcm: [90, -90] * 200, rate: 8000).play # a twentieth of a second, then done
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "MIXQ", code: "BMXQ", maker: "01",
                       built: gba.build_record(b.program))
    v = assert_emulator_loads_rom(rom, frames: 20)
    # How long a buffer is, asked of the build rather than worked out here: how many samples
    # go in a frame is the sound hardware's business (Console::SampleClock), and a test
    # that recomputes it from a round 60 reads past the end of the buffer into what is next.
    frame = v.sample_clock.samples_a_frame

    [gba.mix_buf0, gba.mix_buf1].each do |buffer|
      held = (0...frame).map { |i| v.mem8(buffer + i) }
      assert held.all?(0), "a silent frame, but the buffer held #{held.uniq.inspect}"
    end
  end

  def test_volume_scales_a_voice_on_the_console
    # a steady sample of 40 at :half should mix to 20 (40 * 32 / 64) in the output buffer.
    gba = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = sample :a, pcm: [40] * 400, rate: 8000
      a.play(loop: true, volume: :half)
      game_loop { wait_vblank }
    end
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "VOL0", code: "BVOL", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(20), "a :half voice of 40 should mix to 20, but the buffer held #{mixed.inspect}"
  end
end
