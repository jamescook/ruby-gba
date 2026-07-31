# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The mixer: several samples sound at once instead of cutting each other off — background
# music plus overlapping sound effects, and (later) chords. `sample.play` adds a voice to
# the mix; `sample.stop` drops that sample's voices. This is the interpreter oracle for the
# mixer — it pins the behavior both backends must share (the GBA software-mix lowering
# matches it). The surface stays plain: play and stop, no voices or channels exposed.
class TestMixer < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  # mem8 hands back an unsigned byte; the mix buffer holds signed 8-bit samples.
  def signed8(byte)
    byte >= 128 ? byte - 256 : byte
  end

  # Run a DSL block that sets up sounds, then loops for `frames` frames.
  def run_frames(frames, &setup)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&setup)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add 1
        (counter >= frames).then { halt }
      end
    end
    Ruby.new.run(b.program, max_steps: 200_000)
  end

  def test_two_looping_samples_sound_at_the_same_time
    i = run_frames(30) do
      music = sample :music, pcm: [40, -40] * 400, rate: 8000  # ~0.1s, loops
      hum   = sample :hum, pcm: [20, -20] * 400, rate: 8000
      music.play(loop: true)
      hum.play(loop: true)
    end
    # both are still in the mix together — neither cut the other off
    assert_includes i.active_samples, :music
    assert_includes i.active_samples, :hum
    assert_operator i.peak_voices, :>=, 2, "two voices sounded at once"
  end

  def test_music_plus_two_effects_overlap
    # the acceptance case: background music and two effects going at once = three voices.
    i = run_frames(20) do
      music = sample :music, pcm: [30, -30] * 2000, rate: 8000 # long, loops under the effects
      shot  = sample :shot, pcm: [50, -50] * 2000, rate: 8000
      hit   = sample :hit, pcm: [60, -60] * 2000, rate: 8000
      music.play(loop: true)
      shot.play
      hit.play
    end
    assert_operator i.peak_voices, :>=, 3, "music + two effects mixed together (#{i.peak_voices})"
  end

  def test_stop_drops_only_that_samples_voices
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      music = sample :music, pcm: [30, -30] * 2000, rate: 8000
      blip  = sample :blip, pcm: [10, -10] * 2000, rate: 8000
      music.play(loop: true)
      blip.play(loop: true)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add 1
        (counter == 5).then { blip.stop } # silence just the blip; music keeps going
        (counter >= 20).then { halt }
      end
    end
    i = Ruby.new.run(b.program, max_steps: 200_000)
    assert_includes i.active_samples, :music, "music keeps playing"
    refute_includes i.active_samples, :blip, "the stopped sample is gone from the mix"
  end

  def test_the_same_sample_can_overlap_itself
    # firing one effect rapidly stacks voices (a real sound has echo/overlap, not a restart)
    i = run_frames(10) do
      zap = sample :zap, pcm: [70, -70] * 2000, rate: 8000
      zap.play
      zap.play
      zap.play
    end
    assert_operator i.peak_voices, :>=, 3, "the same effect overlaps itself (#{i.peak_voices})"
  end

  def test_past_the_voice_limit_new_plays_are_dropped_not_crashed
    i = run_frames(5) do
      buzz = sample :buzz, pcm: [25, -25] * 2000, rate: 8000
      20.times { buzz.play } # far more than MAX_VOICES
    end
    assert_equal Ruby::MAX_VOICES, i.peak_voices, "the mix is capped at MAX_VOICES, extra plays dropped"
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
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "MIX0", code: "BMIX", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

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
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "MIXH", code: "BMXH", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

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
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "MIXL", code: "BMXL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(-128), "-200 should saturate to -128, but the buffer held #{mixed.inspect}"
  end

  # --- level control ---

  def test_volume_is_carried_on_the_voice
    i = run_frames(3) do
      m = sample :m, pcm: [50, -50] * 400, rate: 8000
      m.play(loop: true, volume: :half)
    end
    assert_equal :half, i.volume_of(:m), "play(volume:) sets the voice's level"
  end

  def test_a_bad_volume_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        s = sample :s, pcm: [0, 1], rate: 8000
        s.play(volume: :loud)
      end
    end
    assert_match(/level/i, err.message)
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
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "VOL0", code: "BVOL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(20), "a :half voice of 40 should mix to 20, but the buffer held #{mixed.inspect}"
  end
end
