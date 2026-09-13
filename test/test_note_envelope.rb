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
    notes = (0...NOTES).map { |n| RubyGBA::Score::Note.new(at: GAP * n, key: :C4, length: 6 + n) }
    part = RubyGBA::Score::Part.new(plays: :tone, notes: notes, envelope: envelope, volume: 15)
    RubyGBA::Score.new(parts: [part], tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT,
                       length: GAP * (NOTES + 1))
  end

  def build(envelope, holds_from: nil)
    tune = score(envelope)
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
    mono = RubyGBA::Verifier.new(rom, frames: FRAMES).audio_samples.each_slice(2).map(&:first)
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
        (started == 0).then { started.set 1; tone.play(loop: true) }
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
      ends << (i - quiet) if quiet == QUIET_RUN
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

  # A NOTE CAN OUTLAST ITS RECORDING. Without a hold point the recording runs out and the note
  # ends there, however long the note was written; with one it reads round and lasts.
  def test_a_held_note_lasts_longer_than_its_recording
    short = (SINE * 4).freeze # a tenth of a second at most
    tune = RubyGBA::Score.new(
      parts: [RubyGBA::Score::Part.new(plays: :tone, notes: [RubyGBA::Score::Note.new(at: 0, key: :C4, length: 60)])],
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
    tune = RubyGBA::Score.new(
      parts: [RubyGBA::Score::Part.new(plays: :tone, envelope: envelope,
                                       notes: [RubyGBA::Score::Note.new(at: 0, key: :C4, length: 6)])],
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

  # The four numbers, and the two ways an author can say them.
  def test_a_time_becomes_the_number_that_takes_about_that_long
    env = RubyGBA::Envelope.of({ release: 0.4 }, "a part")

    assert_equal 24, RubyGBA::Envelope.frames_to_fall(env.release, RubyGBA::Envelope::FULL, 0)
    assert_equal RubyGBA::Envelope::MOST, env.attack, "a time of nothing is full at once"
    assert_equal RubyGBA::Envelope::MOST, env.sustain, "what is not said holds where it was"
  end

  def test_the_numbers_the_consoles_own_engine_keeps_are_taken_as_they_are
    env = RubyGBA::Envelope.new(attack: 255, decay: 245, sustain: 180, release: 216)

    assert_equal 216, env.release
    assert_equal 0xD8_B4_F5_FF, env.packed
  end

  def test_an_envelope_that_says_nothing_is_the_note_as_it_always_was
    assert_predicate RubyGBA::Envelope.of({}, "a part"), :plain?
    refute_predicate RubyGBA::Envelope.of({ release: 0.2 }, "a part"), :plain?
  end

  # The rule that moves the level, which both backends follow.
  def test_the_level_climbs_holds_and_falls_away
    env = RubyGBA::Envelope.new(attack: 64, decay: 128, sustain: 100, release: 128)
    level, phase = env.step(0, RubyGBA::Envelope::CLIMBING)

    assert_equal [64, RubyGBA::Envelope::CLIMBING], [level, phase]
    level, phase = env.step(200, RubyGBA::Envelope::CLIMBING)

    assert_equal [RubyGBA::Envelope::FULL, RubyGBA::Envelope::HOLDING], [level, phase]
    assert_equal [127, RubyGBA::Envelope::HOLDING], env.step(255, RubyGBA::Envelope::HOLDING)
    assert_equal [100, RubyGBA::Envelope::HOLDING], env.step(100, RubyGBA::Envelope::HOLDING),
                 "it holds at the sustain level rather than falling through it"
    assert_equal [50, RubyGBA::Envelope::FALLING], env.step(100, RubyGBA::Envelope::FALLING)
  end

  # --- what an author is told when they write it wrong ---

  def test_a_time_that_is_not_a_time_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Envelope.of({ release: :slow }, "the part :lead") }

    assert_match(/the part :lead/, error.message)
    assert_match(/release/, error.message)
  end

  def test_a_key_the_envelope_does_not_have_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Envelope.of({ fade: 0.2 }, "the part :lead") }

    assert_match(/fade/, error.message)
    assert_match(/attack/, error.message)
  end

  def test_a_sustain_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Envelope.of({ sustain: 4 }, "the part :lead") }

    assert_match(/sustain/, error.message)
  end

  def test_one_of_the_four_numbers_outside_its_range_names_itself
    error = assert_raises(ArgumentError) { RubyGBA::Envelope.new(attack: 300) }

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
