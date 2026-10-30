# frozen_string_literal: true

require "test_helper"

# The tests of test_note_envelope.rb whose games play their notes from a recording and ask the
# interpreter what is still sounding, which a Game Boy Color's sound hardware cannot play, so they
# play on the Advance's runs alone.
class TestNoteEnvelopeOnTheAdvance < Minitest::Test
  include EmulatorSupport

  # A second of a sine, cut at a zero crossing so the recording itself has no step in it.
  CYCLE = 64
  RATE = 8000
  SINE = (0...CYCLE).map { |i| (Math.sin(i * 2 * Math::PI / CYCLE) * 100).round }.freeze
  RECORDING = (SINE * (RATE / CYCLE)).freeze

  # A tempo where one tick is one frame, so a note's length is said in frames.
  TEMPO = 150
  TICKS_PER_BEAT = 24

  # --- and the same on the other backend, which has to agree about when a note is over ---

  # Run a one-note song on the reference interpreter for +frames+ frames and hand back the
  # interpreter, so a test can ask what is still sounding.
  private def interpret(envelope, frames:)
    tune = VBlank::Audio::Score.new(
      parts: [VBlank::Audio::Score::Part.new(plays: :tone, envelope: envelope,
                                       notes: [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 6)])],
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
    builder.finalize_program
    game_player.tap { |ruby| ruby.run(builder.program, frames: frames) }
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

  VOICES = VBlank::Audio::Sound::MIXER_VOICES
  SLOW_RELEASE = VBlank::Audio::Envelope.new(release: 250) # still sounding a good second after its note

  # A game with two recordings, a part that plays +notes+ shaped by SLOW_RELEASE, and — on pass
  # +burst+ — as many sounds of the game's own as there are voices.
  private def voices_game(notes, burst: nil)
    tune = VBlank::Audio::Score.new(
      parts: [VBlank::Audio::Score::Part.new(plays: :low, envelope: SLOW_RELEASE, notes: notes)],
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
    b.finalize_program
    b.program
  end

  # What each backend has sounding +frames+ in, and what each could not play.
  private def voices_on_both(program, frames:)
    ruby = game_player.run(program, frames: frames)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TAILS"), frames: frames + 2)
    [[ruby.active_samples, ruby.sound_drops], [console.sounding, console.sound_drops]]
  end

  def test_a_parts_next_note_leaves_the_last_falling_on_its_own_voice
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, instrument: :low),
             VBlank::Audio::Score::Note.new(at: 10, key: :C4, instrument: :high)]
    (ruby, _), (console, _) = voices_on_both(voices_game(notes), frames: 14)

    assert_equal %i[low high], ruby, "the first note falls away on its voice while the second sounds on another"
    assert_equal ruby, console
  end

  def test_a_game_sound_takes_a_falling_notes_voice_rather_than_being_dropped
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 4)]
    ruby, console = voices_on_both(voices_game(notes, burst: 10), frames: 14)

    clips = (0...VOICES).map { |n| :"s#{n}" }

    assert_equal [clips.last] + clips[0...-1], ruby.first,
                 "every voice is the game's: the last sound took the first voice, which the falling note gave up"
    assert_equal 0, ruby.last.dropped
    assert_equal ruby, console
  end
end
