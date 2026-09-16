# frozen_string_literal: true

require "test_helper"

# HOW A NOTE STARTS AND HOW IT ENDS — the shape of its loudness over time, and the two things
# that shape buys: a note that ends without a click, and a note that can outlast the recording
# it is made of.
#
# The click is the point of the whole feature, so the console test measures it the way the
# report that asked for this measured it: a sine of a whole number of cycles is played, and the
# biggest jump between one sample of the rendering and the next is held against the biggest jump
# the WAVE ITSELF ever makes. A note cut dead leaves the speaker wherever the wave was, and that
# jump is several times the wave's own. A note that fades does not.
class TestNoteEnvelope < Minitest::Test
  include EmulatorSupport

  # A second of a sine, cut at a zero crossing so the recording itself has no step in it.
  CYCLE = 64
  RATE = 8000
  SINE = (0...CYCLE).map { |i| (Math.sin(i * 2 * Math::PI / CYCLE) * 100).round }.freeze
  RECORDING = (SINE * (RATE / CYCLE)).freeze

  # Six notes, each a frame longer than the last, so the six of them END AT SIX DIFFERENT POINTS
  # of the wave. That is what makes the click "only sometimes": a note that happens to end near
  # a zero crossing is quiet about it, and one that ends near a peak is not.
  #
  # The rests between them are long because the fade under test is half a second: a rest shorter
  # than the fade leaves no silence to find a note's end by, and the next note takes the voice
  # over while the last one is still sounding.
  NOTES = 6
  GAP = 55
  FRAMES = GAP * (NOTES + 1)

  # A tempo where one tick is one frame, so a note's length is said in frames.
  TEMPO = 150
  TICKS_PER_BEAT = 24

  def score(envelope)
    notes = (0...NOTES).map { |n| RubyGBA::Audio::Score::Note.new(at: GAP * n, key: :C4, length: 6 + n) }
    tune_of(notes, envelope)
  end

  def tune_of(notes, envelope)
    part = RubyGBA::Audio::Score::Part.new(plays: :tone, notes: notes, envelope: envelope, volume: 15)
    RubyGBA::Audio::Score.new(parts: [part], tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT,
                       length: GAP * (NOTES + 1))
  end

  def build(envelope, holds_from: nil, tune: score(envelope))
    RubyGBA.build("ENVELOPE", code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: RECORDING, rate: RATE, note: :C4, holds_from: holds_from
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end
  end

  # One channel of the rendering, and the jump from each sample to the next.
  def rendered(rom)
    mono = RubyGBA::Diagnostics::Verifier.new(rom, frames: FRAMES).audio_samples.each_slice(2).map(&:first)
    [mono, mono.each_cons(2).map { |a, b| (b - a).abs }]
  end

  # THE BIGGEST JUMP THE WAVE ITSELF MAKES — the bar everything else is held against. Measured
  # on the same recording played round and round with no note ever starting or stopping, so
  # there is nothing in it but the wave, and measured rather than worked out because what
  # reaches the test is the console's output through the emulator's own resampling.
  def the_waves_own_step
    control = RubyGBA.build("ENVELOPE", code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      tone = sample :tone, pcm: RECORDING, rate: RATE, note: :C4
      started = var :started, 0
      game_loop do
        (started == 0).then { started.set! 1; tone.play(loop: true) }
        clear_screen :black
      end
    end
    rendered(control).last.max
  end

  # WHERE EACH NOTE ENDS, found in the rendering itself rather than counted out in frames. Every
  # note here is followed by a rest, so a note's end is where the sound falls to nothing — and
  # the biggest jump in the run-up to that silence is the one a click would be.
  #
  # Found this way because a frame counted from the outside drifts: the run is long, and the
  # emulator hands over its sound in chunks that do not divide evenly into frames. A silence is
  # exactly where it is.
  QUIET = 400        # below this the speaker is as good as still
  QUIET_RUN = 1500   # ...and this many in a row is a rest rather than a zero crossing

  def steps_at_note_ends(mono, steps)
    ends = []
    quiet = 0
    mono.each_index do |i|
      quiet = mono[i].abs < QUIET ? quiet + 1 : 0
      ends << (i - quiet) if quiet == QUIET_RUN && i >= quiet # the silence before the first note ends nothing
    end
    ends.map { |at| steps[[at - QUIET_RUN, 0].max..at].max }
  end

  def test_a_note_that_stops_dead_clicks_and_a_note_that_fades_does_not
    require_emulator!
    own = the_waves_own_step

    mono, steps = rendered(build(nil))
    stopping = steps_at_note_ends(mono, steps)

    assert_equal NOTES, stopping.length, "every note should be followed by a rest"
    assert_operator stopping.max, :>, own * 3,
                    "a note that stops dead should end with a jump far past the wave's own " \
                    "(#{own}); the note ends measured #{stopping.inspect}"
    assert_operator stopping.count { |step| step > mono.map(&:abs).max / 2 }, :>, 0,
                    "...and some of them by more than half the whole wave"

    mono, steps = rendered(build({ release: 0.5 }))
    fading = steps_at_note_ends(mono, steps)

    assert_equal NOTES, fading.length, "every note should still be followed by a rest"
    fading.each_with_index do |step, n|
      assert_operator step, :<=, own,
                      "note #{n} ends with a jump of #{step}, and the wave's own is #{own}"
    end
  end

  # THE FASTEST RELEASE ON A RETAIL CARTRIDGE: 89, which keeps about a third of the level each
  # frame and is silent in six. Most of that fall happens in the first frame, so a level that moved
  # only at the frame boundary took most of the wave away in one step — a click, a smaller one than
  # stopping dead but the same thing. The gain slides across the frame instead.
  FASTEST_RETAIL_RELEASE = RubyGBA::Audio::Envelope.new(release: 89)

  def test_the_fastest_retail_release_ends_a_note_without_a_jump
    require_emulator!
    own = the_waves_own_step

    mono, steps = rendered(build(FASTEST_RETAIL_RELEASE))
    ends = steps_at_note_ends(mono, steps)

    assert_equal NOTES, ends.length, "every note should be followed by a rest"
    ends.each_with_index do |step, n|
      assert_operator step, :<=, own, "note #{n} ends with a jump of #{step}, and the wave's own is #{own}"
    end
  end

  # A NOTE THAT COMES BEFORE THE LAST ONE HAS FINISHED FADING. The last one falls away on its own
  # voice while the new one sounds on another, so for a moment two waves are playing — and two
  # waves together can move twice as far in a sample as one. Anything past that is a break in the
  # sound: the new note taking the old one's voice would stop the old wave dead mid-fade.
  #
  # Each note lasts until the next, and each is a frame longer than the last, so they end at
  # different points of the wave. A slow release as well as the fast one, since a slow fade is
  # still loud when the next note arrives.
  def test_a_note_that_arrives_mid_fade_does_not_cut_the_fade_off
    require_emulator!
    own = the_waves_own_step
    notes = (0..NOTES).map { |n| RubyGBA::Audio::Score::Note.new(at: (0...n).sum { |k| 8 + k }, key: :C4) }

    [FASTEST_RETAIL_RELEASE, RubyGBA::Audio::Envelope.new(release: 188)].each do |shape|
      _, steps = rendered(build(shape, tune: tune_of(notes, shape)))

      assert_operator steps.max, :<=, own * 2,
                      "release #{shape.release}: a jump of #{steps.max}, and two waves together move #{own * 2} at most"
    end
  end

  # A NOTE CAN OUTLAST ITS RECORDING. Without a hold point the recording runs out and the note
  # ends there, however long the note was written; with one it reads round and lasts.
  def test_a_held_note_lasts_longer_than_its_recording
    short = (SINE * 4).freeze # a tenth of a second at most
    tune = RubyGBA::Audio::Score.new(
      parts: [RubyGBA::Audio::Score::Part.new(plays: :tone, notes: [RubyGBA::Audio::Score::Note.new(at: 0, key: :C4, length: 60)])],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 90
    )
    held = RubyGBA.build("ENVELOPE", code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: short, rate: RATE, note: :C4, holds_from: 0
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end

    voice = assert_emulator_loads_rom(held, frames: 40).voices.first

    refute_nil voice, "the held note should still be sounding well past the recording's end"
    assert voice.loop, "a held note reads round rather than running out"
  end

  # --- and the same on the other backend, which has to agree about when a note is over ---

  # Run a one-note song on the reference interpreter for +frames+ frames and hand back the
  # interpreter, so a test can ask what is still sounding.
  def interpret(envelope, frames:)
    tune = RubyGBA::Audio::Score.new(
      parts: [RubyGBA::Audio::Score::Part.new(plays: :tone, envelope: envelope,
                                       notes: [RubyGBA::Audio::Score::Note.new(at: 0, key: :C4, length: 6)])],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 90
    )
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: RECORDING, rate: RATE, note: :C4
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end
    builder.emit_pending_functions
    Reference.new.tap { |ruby| ruby.run(builder.program, frames: frames) }
  end

  def test_the_interpreter_lets_a_shaped_note_fall_away_and_stops_a_plain_one
    # The note ends on frame 6. A frame after that, a plain note is gone...
    assert_empty interpret(nil, frames: 10).active_samples,
                 "a note with no shape stops the moment it ends"

    # ...and a shaped one is still sounding, more quietly each frame.
    fading = interpret({ release: 0.5 }, frames: 10)

    assert_equal [:tone], fading.active_samples, "a shaped note goes on sounding as it falls"
    later = interpret({ release: 0.5 }, frames: 20)

    assert_operator later.level_of(:tone), :<, fading.level_of(:tone),
                    "...and it is quieter the longer it has been falling"
    assert_empty interpret({ release: 0.5 }, frames: 90).active_samples,
                 "and in the end it is over, and its voice goes back"
  end

  # --- the voices a falling note holds, which both backends have to agree about ---

  VOICES = RubyGBA::Audio::Sound::MIXER_VOICES
  SLOW_RELEASE = RubyGBA::Audio::Envelope.new(release: 250) # still sounding a good second after its note

  # A game with two recordings, a part that plays +notes+ shaped by SLOW_RELEASE, and — on pass
  # +burst+ — as many sounds of the game's own as there are voices.
  def voices_game(notes, burst: nil)
    tune = RubyGBA::Audio::Score.new(
      parts: [RubyGBA::Audio::Score::Part.new(plays: :low, envelope: SLOW_RELEASE, notes: notes)],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 200
    )
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :low, pcm: RECORDING, rate: RATE, note: :C4, holds_from: 0
      instrument :high, pcm: RECORDING, rate: RATE, note: :C4, holds_from: 0
      clips = (0...VOICES).map { |n| sample :"s#{n}", pcm: [25 + n, -25 - n] * 8000, rate: 8000 }
      music = songs :music, [tune]
      music.play 0
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == burst).then { clips.each(&:play) } if burst
      end
    end
    b.emit_pending_functions
    b.program
  end

  # What each backend has sounding +frames+ in, and what each could not play.
  def voices_on_both(program, frames:)
    ruby = Reference.new.run(program, frames: frames)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TAILS"), frames: frames + 2)
    [[ruby.active_samples, ruby.sound_drops], [console.sounding, console.sound_drops]]
  end

  def test_a_parts_next_note_leaves_the_last_falling_on_its_own_voice
    notes = [RubyGBA::Audio::Score::Note.new(at: 0, key: :C4, instrument: :low),
             RubyGBA::Audio::Score::Note.new(at: 10, key: :C4, instrument: :high)]
    (ruby, _), (console, _) = voices_on_both(voices_game(notes), frames: 14)

    assert_equal %i[low high], ruby, "the first note falls away on its voice while the second sounds on another"
    assert_equal ruby, console
  end

  def test_a_game_sound_takes_a_falling_notes_voice_rather_than_being_dropped
    notes = [RubyGBA::Audio::Score::Note.new(at: 0, key: :C4, length: 4)]
    ruby, console = voices_on_both(voices_game(notes, burst: 10), frames: 14)

    clips = (0...VOICES).map { |n| :"s#{n}" }

    assert_equal [clips.last] + clips[0...-1], ruby.first,
                 "every voice is the game's: the last sound took the first voice, which the falling note gave up"
    assert_equal 0, ruby.last.dropped
    assert_equal ruby, console
  end

  # The four numbers, and the two ways an author can say them.
  def test_a_time_becomes_the_number_that_takes_about_that_long
    env = RubyGBA::Audio::Envelope.of({ release: 0.4 }, "a part")

    assert_equal 24, RubyGBA::Audio::Envelope.frames_to_fall(env.release, RubyGBA::Audio::Envelope::FULL, 0)
    assert_equal RubyGBA::Audio::Envelope::MOST, env.attack, "a time of nothing is full at once"
    assert_equal RubyGBA::Audio::Envelope::MOST, env.sustain, "what is not said holds where it was"
  end

  def test_the_numbers_the_consoles_own_engine_keeps_are_taken_as_they_are
    env = RubyGBA::Audio::Envelope.new(attack: 255, decay: 245, sustain: 180, release: 216)

    assert_equal 216, env.release
    assert_equal 0xD8_B4_F5_FF, env.packed
  end

  def test_an_envelope_that_says_nothing_is_the_note_as_it_always_was
    assert_predicate RubyGBA::Audio::Envelope.of({}, "a part"), :plain?
    refute_predicate RubyGBA::Audio::Envelope.of({ release: 0.2 }, "a part"), :plain?
  end

  # The rule that moves the level, which both backends follow.
  def test_the_level_climbs_holds_and_falls_away
    env = RubyGBA::Audio::Envelope.new(attack: 64, decay: 128, sustain: 100, release: 128)
    level, phase = env.step(0, RubyGBA::Audio::Envelope::CLIMBING)

    assert_equal [64, RubyGBA::Audio::Envelope::CLIMBING], [level, phase]
    level, phase = env.step(200, RubyGBA::Audio::Envelope::CLIMBING)

    assert_equal [RubyGBA::Audio::Envelope::FULL, RubyGBA::Audio::Envelope::HOLDING], [level, phase]
    assert_equal [127, RubyGBA::Audio::Envelope::HOLDING], env.step(255, RubyGBA::Audio::Envelope::HOLDING)
    assert_equal [100, RubyGBA::Audio::Envelope::HOLDING], env.step(100, RubyGBA::Audio::Envelope::HOLDING),
                 "it holds at the sustain level rather than falling through it"
    assert_equal [50, RubyGBA::Audio::Envelope::FALLING], env.step(100, RubyGBA::Audio::Envelope::FALLING)
  end

  # --- what an author is told when they write it wrong ---

  def test_a_time_that_is_not_a_time_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Audio::Envelope.of({ release: :slow }, "the part :lead") }

    assert_match(/the part :lead/, error.message)
    assert_match(/release/, error.message)
  end

  def test_a_key_the_envelope_does_not_have_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Audio::Envelope.of({ fade: 0.2 }, "the part :lead") }

    assert_match(/fade/, error.message)
    assert_match(/attack/, error.message)
  end

  def test_a_sustain_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Audio::Envelope.of({ sustain: 4 }, "the part :lead") }

    assert_match(/sustain/, error.message)
  end

  def test_one_of_the_four_numbers_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Audio::Envelope.new(attack: 300) }

    assert_match(/attack/, error.message)
    assert_match(/0 to 255/, error.message)
  end

  def test_a_hold_point_outside_the_recording_names_itself
    error = assert_raises(ArgumentError) do
      RubyGBA.build("ENVELOPE", code: "BENV", maker: "01", validate: false) do
        screen :bitmap
        enable_sound
        instrument :tone, pcm: SINE, rate: RATE, note: :C4, holds_from: 5.0
      end
    end

    assert_match(/holds from/, error.message)
    assert_match(/:tone/, error.message)
  end
end
