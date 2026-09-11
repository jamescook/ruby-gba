# frozen_string_literal: true

require "test_helper"

# The mixer: several samples sound at once instead of cutting each other off — background
# music plus overlapping sound effects, and (later) chords. `sample.play` adds a voice to
# the mix; `sample.stop` drops that sample's voices. This is the interpreter oracle for the
# mixer — it pins the behavior both backends must share (the GBA software-mix lowering
# matches it). The surface stays plain: play and stop, no voices or channels exposed.
class TestMixer < Minitest::Test

  # mem8 hands back an unsigned byte; the mix buffer holds signed 8-bit samples.
  def signed8(byte)
    byte >= 128 ? byte - 256 : byte
  end

  # A DSL block that sets up sounds, then loops for `frames` frames — as a program, so the
  # interpreter and the console can be handed the very same one rather than two that look
  # alike.
  def frames_program(frames, &setup)
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
    b.program
  end

  # ...and run it on the interpreter, which is what nearly every test here wants.
  def run_frames(frames, &setup)
    Reference.new.run(frames_program(frames, &setup), max_steps: 200_000)
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
    i = Reference.new.run(b.program, max_steps: 200_000)
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

  # OVER-SUBSCRIBE THE MIXER AND ASK BOTH BACKENDS WHAT HAPPENED. The assertion is against
  # Sound::MIXER_VOICES — the promise the two backends make to each other — and not against
  # either one's own constant. Asserting the interpreter's cap against the interpreter's
  # behaviour is true whatever the number says and silent about the lowering, which is how
  # the limit came to be written down twice with nothing holding the two together.
  def test_past_the_voice_limit_new_plays_are_dropped_not_crashed
    i = run_frames(5) do
      buzz = sample :buzz, pcm: [25, -25] * 2000, rate: 8000
      20.times { buzz.play } # far more than the mixer holds
    end
    assert_equal RubyGBA::Sound::MIXER_VOICES, i.peak_voices,
                 "the mix is capped at the shared limit, extra plays dropped"
  end

  # THE VOICE TABLE DECODES WHATEVER MEMORY IT IS HANDED. The reader is passed in rather than
  # owned, so the decoding — which slot is sounding, which sample it is, whether it loops — is
  # checked here against a plain Hash, with no emulator anywhere. This is the one test that
  # knows the slot layout, which is right: it is the mixer's own.
  def test_the_voice_table_reads_the_sounding_slots_out_of_any_memory
    base = 0x0300_0000
    table = GBA::Mixer::VoiceTable.new(base: base, count: 3,
                                       sample_addresses: { zap: 0x0800_1000, hum: 0x0800_2000 })
    at = ->(slot, field) { base + (slot * GBA::Mixer::SLOT_BYTES) + field }
    memory = Hash.new(0)
    memory[at[0, GBA::Mixer::SLOT_ACTIVE]] = 1 # slot 0 sounds :zap ...
    memory[at[0, GBA::Mixer::SLOT_SRC]] = 0x0800_1000
    memory[at[0, GBA::Mixer::SLOT_POS]] = 40
    memory[at[2, GBA::Mixer::SLOT_ACTIVE]] = 1 # ...slot 1 is idle, slot 2 loops :hum
    memory[at[2, GBA::Mixer::SLOT_SRC]] = 0x0800_2000
    memory[at[2, GBA::Mixer::SLOT_LOOP]] = 1

    voices = table.read { |address| memory[address] }

    assert_equal %i[zap hum], voices.map(&:sample), "the idle slot between them is skipped"
    assert_equal 40, voices.first.position
    assert voices.last.loop, "the looping flag reads back as true"
    refute voices.first.loop
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

    error = assert_raises(ArgumentError) { RubyGBA::Verifier.new(bare, frames: 1).voices }
    assert_match(/build record/, error.message)
  end

  # TWO MORE DIFFERENT SOUNDS THAN THE MIXER HAS VOICES, AND BOTH BACKENDS MUST KEEP THE SAME
  # ONES. The mixer drops a play it has no room for rather than cutting off one already
  # sounding, so the first ones played are the ones that sound and the last two are lost.
  #
  # A count alone would not show that: two backends can each hold a full mixer and disagree
  # about which. So ask each one what it is playing, by name. The console answers from its
  # own voice table — reading what the lowering really did, not what the interpreter says
  # it should have — and the two lists have to match.
  SOUNDS = (0...(RubyGBA::Sound::MIXER_VOICES + 2)).map { |i| :"s#{i}" }

  def test_both_backends_keep_the_same_sounds_when_the_mixer_is_full
    # Each sample gets bytes of its own, so no two can ever share a place in the cartridge and
    # read back under each other's name — this test is about the mixer, not about whether the
    # build happens to store identical sounds once.
    program = frames_program(5) do
      SOUNDS.each_with_index.map { |name, i| sample name, pcm: [25 + i, -25 - i] * 2000, rate: 8000 }
            .each(&:play)
    end
    kept = SOUNDS.first(RubyGBA::Sound::MIXER_VOICES)

    interpreted = Reference.new.run(program, max_steps: 200_000).active_samples
    assert_equal kept, interpreted, "the interpreter keeps the first #{kept.size} and drops the rest"

    console = assert_emulator_loads_rom(assemble_rom(program), frames: 6).sounding
    assert_equal interpreted, console, "the console keeps the same ones the interpreter does"
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
    b.emit_pending_functions
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
    b.emit_pending_functions
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
    b.emit_pending_functions
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
    b.emit_pending_functions
    rom = ROM.assemble(gba.lower(b.program), title: "MIXQ", code: "BMXQ", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20)
    frame = (8000 + 59) / 60

    [gba.mix_buf0, gba.mix_buf1].each do |buffer|
      held = (0...frame).map { |i| v.mem8(buffer + i) }
      assert held.all?(0), "a silent frame, but the buffer held #{held.uniq.inspect}"
    end
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
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(20), "a :half voice of 40 should mix to 20, but the buffer held #{mixed.inspect}"
  end
end
