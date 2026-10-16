# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# The mixer: several samples sound at once instead of cutting each other off — background
# music plus overlapping sound effects, and (later) chords. `sample.play` adds a voice to
# the mix; `sample.stop` drops that sample's voices. This is the interpreter oracle for the
# mixer — it pins the behavior both backends must share (the GBA software-mix lowering
# matches it), down to every byte of sound it makes. The surface stays plain: play and
# stop, no voices or channels exposed.
class TestMixer < Minitest::Test
  runs_on :reference, :native
  include MixedSound

  # mem8 hands back an unsigned byte; the mix buffer holds signed 8-bit samples.
  private def signed8(byte)
    byte >= 128 ? byte - 256 : byte
  end

  # A DSL block that sets up sounds, then loops for `frames` frames — as a program, so the
  # interpreter and the console can be handed the very same one rather than two that look
  # alike.
  private def frames_program(frames, &setup)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&setup)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add! 1
        (counter >= frames).then { halt }
      end
    end
    b.program
  end

  # ...and run it on the interpreter, which is what nearly every test here wants.
  private def run_frames(frames, &setup)
    game_player.run(frames_program(frames, &setup), max_steps: 200_000)
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
        counter.add! 1
        (counter == 5).then { blip.stop } # silence just the blip; music keeps going
        (counter >= 20).then { halt }
      end
    end
    i = game_player.run(b.program, max_steps: 200_000)
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
    assert_equal RubyGBA::Audio::Sound::MIXER_VOICES, i.peak_voices,
                 "the mix is capped at the shared limit, extra plays dropped"
  end

  # THE VOICE TABLE DECODES WHATEVER MEMORY IT IS HANDED. The reader is passed in rather than
  # owned, so the decoding — which slot is sounding, which sample it is, whether it loops — is
  # checked here against a plain Hash, with no emulator anywhere. This is the one test that
  # knows the slot layout, which is right: it is the mixer's own.
  def test_the_voice_table_reads_the_sounding_slots_out_of_any_memory
    base = 0x0300_0000
    table = GBA::Mixer::VoiceTable.new(base: base, count: 3,
                                       clock: GBA::Timers.sample_clock(8000),
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

    error = assert_raises(ArgumentError) { RubyGBA::Diagnostics::Verifier.new(bare, frames: 1).voices }
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
  SOUNDS = (0...(RubyGBA::Audio::Sound::MIXER_VOICES + 2)).map { |i| :"s#{i}" }

  def test_both_backends_keep_the_same_sounds_when_the_mixer_is_full
    # Each sample gets bytes of its own, so no two can ever share a place in the cartridge and
    # read back under each other's name — this test is about the mixer, not about whether the
    # build happens to store identical sounds once.
    program = frames_program(5) do
      SOUNDS.each_with_index.map { |name, i| sample name, pcm: [25 + i, -25 - i] * 2000, rate: 8000 }
            .each(&:play)
    end
    kept = SOUNDS.first(RubyGBA::Audio::Sound::MIXER_VOICES)

    interpreted = game_player.run(program, max_steps: 200_000).active_samples
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
    # go in a frame is the sound hardware's business (GBA::Timers.sample_clock), and a test
    # that recomputes it from a round 60 reads past the end of the buffer into what is next.
    frame = v.sample_clock.samples_a_frame

    [gba.mix_buf0, gba.mix_buf1].each do |buffer|
      held = (0...frame).map { |i| v.mem8(buffer + i) }
      assert held.all?(0), "a silent frame, but the buffer held #{held.uniq.inspect}"
    end
  end

  # --- the sound itself, byte for byte (see MixedSound) ---

  # A game that plays its recordings on its first pass and then does nothing.
  private def playing(&plays)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&plays)
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  # A recording whose every byte differs from the one beside it, so a slice that starts a
  # sample early or late, or reads one twice, is a different slice.
  SAWTOOTH = Array.new(4000) { |i| (i % 200) - 100 }.freeze

  # A recording declared and never played is nothing to mix, so there is no mix at all, as on
  # the cartridge, which brings its mixer up only for a game that plays one.
  def test_a_game_that_only_declares_a_recording_mixes_nothing
    declared = playing { sample(:saw, pcm: SAWTOOTH, rate: 8000) }

    assert_empty game_player.run(declared, frames: 5).mixed_sound
  end

  def test_one_recording_is_mixed_into_the_same_bytes
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000).play })
  end

  def test_a_quieter_play_is_the_same_bytes
    %i[three_quarter half quarter].each do |level|
      assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000).play(volume: level) })
    end
  end

  # A note other than the one it was recorded at reads the recording faster or slower, by a
  # step that is not a whole number of samples, and the part left over is carried frame to
  # frame. So is a recording made at another rate than the mix runs at.
  def test_a_recording_read_at_another_pitch_or_rate_is_the_same_bytes
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000, note: :C4).play(pitch: :E4) })
    assert_mixes_agree(playing { sample(:saw, pcm: SAWTOOTH, rate: 8000, note: :C4).play(pitch: :A3) })
    assert_mixes_agree(playing do
      sample(:other, pcm: SAWTOOTH, rate: 11_025).play
      sample(:common, pcm: [3] * 10, rate: 8000)
      sample(:common_too, pcm: [4] * 10, rate: 8000)
    end)
  end

  # A recording shorter than a frame's worth ends partway through a slice, and the rest of
  # that slice is silent; the frame after is silence through and through.
  def test_a_recording_that_ends_partway_through_a_frame_is_the_same_bytes
    short = Array.new(300) { |i| (i % 50) - 25 }
    assert_mixes_agree(playing { sample(:blip, pcm: short, rate: 8000).play }, frames: 6)
  end

  def test_a_recording_that_loops_or_holds_is_the_same_bytes
    loop_me = Array.new(150) { |i| (i % 30) - 15 }
    assert_mixes_agree(playing { sample(:round, pcm: loop_me, rate: 8000).play(loop: true) })
    assert_mixes_agree(playing { sample(:held, pcm: SAWTOOTH.first(500), rate: 8000, holds_from: 320).play(loop: true) })
  end

  # A hold of two samples read two octaves up steps about four at a time, so one read back is not
  # enough to be inside the recording again: it reads back as many times as it takes, and
  # never reads what is stored after the recording.
  def test_a_hold_shorter_than_a_step_is_the_same_bytes
    assert_mixes_agree(playing do
      sample(:held, pcm: SAWTOOTH.first(100), rate: 8000, note: :C4, holds_from: 98).play(pitch: :C6, loop: true)
    end)
  end

  # The same for a recording that loops whole and is shorter than one step.
  def test_a_loop_shorter_than_a_step_is_the_same_bytes
    assert_mixes_agree(playing do
      sample(:tiny, pcm: SAWTOOTH.first(3), rate: 8000, note: :C4).play(pitch: :C6, loop: true)
    end)
  end

  # A recording declared with a shape climbs and settles when the game plays it, its loudness
  # sliding across every sample of a frame.
  def test_a_recording_with_a_shape_is_the_same_bytes
    shape = { attack: 0.1, decay: 0.2, sustain: 0.4 }
    assert_mixes_agree(playing { sample(:swell, pcm: SAWTOOTH, rate: 8000, envelope: shape).play(loop: true) })
  end

  # ...and one the game starts and stops in its loop lands on the same frames, a frame's slice
  # made after the pass that said it — mixed once at nothing before its shape first moves it.
  def test_a_shaped_recording_started_and_stopped_in_the_loop_is_the_same_bytes
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clip = sample :clip, pcm: SAWTOOTH.reverse, rate: 8000, envelope: { attack: 0.1 }
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        (passes == 3).then { clip.play }
        (passes == 12).then { clip.stop }
      end
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 20, at_least: 6)
  end

  # A recording declared twice under one name plays the second declaration's samples.
  def test_a_name_declared_twice_plays_the_last_recording
    assert_mixes_agree(playing do
      sample(:saw, pcm: SAWTOOTH, rate: 8000)
      sample(:saw, pcm: SAWTOOTH.reverse, rate: 8000).play
    end)
  end

  # Several voices summed, each total held to a byte only once every voice is in.
  def test_several_recordings_summed_and_clamped_are_the_same_bytes
    loud = Array.new(3000) { |i| ((i * 7) % 256) - 128 }
    assert_mixes_agree(playing do
      sample(:saw, pcm: SAWTOOTH, rate: 8000).play
      sample(:loud, pcm: loud, rate: 8000).play(pitch: :D4)
      sample(:also, pcm: loud.reverse, rate: 8000).play(volume: :half, loop: true)
    end)
  end

  # A recorded instrument played by a song: notes of their own pitch and loudness, rests that
  # give the voice back, and a note that takes over its part's own voice from the top.
  private def tune_on(instrument_words: {}, part_words: {}, volume_from: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4, **instrument_words
      song :tune do
        tempo 300
        voice :melody, plays: :keys, **part_words do
          volume 13
          note :C4, :quarter
          note :E4, :quarter
          rest :quarter
          note :G4, :eighth
          note :C5, :eighth
          volume 9
          note :A4, :half
        end
        voice :under, plays: :keys do
          volume 6
          note :C3, :whole
        end
      end
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        play_song :tune
        (passes == volume_from).then { music_volume 40 } if volume_from
      end
    end
    b.finalize_program
    b.program
  end

  # A Score's note can name its own recording and its own shape, over its part's: here the second
  # note is another recording, and the third the part's own recording with a shape of its own.
  def test_a_notes_own_recording_and_shape_are_the_same_bytes
    score = RubyGBA::Audio::Score
    notes = [score::Note.new(at: 0, key: :C4, length: 8),
             score::Note.new(at: 10, key: :E4, instrument: :reed, length: 8),
             score::Note.new(at: 20, key: :G4, envelope: { attack: 0.1, release: 0.1 }, length: 10)]
    tune = score.new(tempo: 150, length: 40, parts: [score::Part.new(plays: :keys, notes: notes)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(2400), rate: 8000, note: :C4
      instrument :reed, pcm: SAWTOOTH.reverse.first(2400), rate: 8000, note: :C4
      music = songs :music, [tune]
      game_loop { music.play 0 }
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 40)
  end

  def test_a_songs_recorded_parts_are_the_same_bytes
    assert_mixes_agree(tune_on, frames: 60)
  end

  # A note with a shape climbs, holds and falls away, its loudness sliding across every sample
  # of a frame rather than stepping at the frame's edge.
  def test_notes_with_a_shape_are_the_same_bytes
    shaped = { envelope: { attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.15 } }
    assert_mixes_agree(tune_on(instrument_words: shaped), frames: 60)
    assert_mixes_agree(tune_on(part_words: { envelope: { release: 0.3 } }), frames: 60)
  end

  # The music volume moving reaches notes already sounding — with and without a shape in the
  # game, which changes what the mix reads for a note with none.
  def test_the_music_volume_moving_is_the_same_bytes
    assert_mixes_agree(tune_on(volume_from: 8), frames: 60)
    assert_mixes_agree(tune_on(part_words: { envelope: { release: 0.2 } }, volume_from: 8), frames: 60)
  end

  # A note at volume 0 sounds nothing, so it takes no voice: the part is silent there, and the
  # part's voice from before it is let go as a rest lets it go.
  def test_a_note_at_volume_nought_is_the_same_bytes
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4
      song :tune do
        tempo 300
        voice :melody, plays: :keys do
          volume 12
          note :C4, :quarter
          volume 0
          note :E4, :quarter
          volume 12
          note :G4, :quarter
        end
      end
      game_loop { play_song :tune }
    end
    b.finalize_program
    assert_mixes_agree(b.program, frames: 40)
  end

  # WHAT A GAME DOES INSIDE ITS LOOP is mixed in the slice made just after its pass, so against a
  # tune that is already sounding, a sound the game starts or stops lands on the cartridge's
  # frame — and a sound with a shape is mixed once at nothing before its shape first moves it.
  def test_a_sound_the_game_starts_and_stops_in_its_loop_lands_on_the_same_frame
    [{}, { envelope: { attack: 0.1, release: 0.2 } }].each do |shape|
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instrument :keys, pcm: SAWTOOTH.first(1200), rate: 8000, note: :C4
        clip = sample :clip, pcm: SAWTOOTH.reverse, rate: 8000, **shape
        song :tune do
          tempo 300
          voice(:melody, plays: :keys) { note :C4, :whole }
        end
        passes = var :passes, 0
        game_loop do
          passes.add! 1
          play_song :tune
          (passes == 6).then { clip.play }
          (passes == 14).then { clip.stop }
        end
      end
      b.finalize_program
      assert_mixes_agree(b.program, frames: 30)
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
    b.finalize_program
    rom = ROM.assemble(gba.lower(b.program), title: "VOL0", code: "BVOL", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    mixed = (0...8).map { |i| signed8(v.mem8(gba.mix_buf0 + i)) }
    assert mixed.all?(20), "a :half voice of 40 should mix to 20, but the buffer held #{mixed.inspect}"
  end
end
