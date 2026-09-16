# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song needs a voice for every one of its parts at once: one of the console's two square-wave
# voices for each plain part, and one of the mixer's for each part that plays an instrument. Past
# either number some part would never be heard, so the build stops and says which song and what
# to do — for a song block and for a Score alike, since both reach the same program.
class TestSongTooManyPartsGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::SongTooManyParts
  Part = RubyGBA::Score::Part
  Note = RubyGBA::Score::Note

  # One more part that plays an instrument than the mixer has voices.
  TOO_MANY = RubyGBA::Sound::MIXER_VOICES + 1

  # A part on whichever voice: an instrument by name, or `wave:`/`noise:` for the two the
  # console plays itself. Naming none of them is a square-wave part.
  def part(instrument = nil, **plays)
    RubyGBA::Music::Part.new(events: [[0, 262]], instrument: instrument, **plays)
  end

  def detect(voices) = Check.new.detect(program(song(:big, total_frames: 4, voices: voices)))

  def test_a_third_square_wave_part_stops_the_build
    findings = detect([part, part, part])

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/3 parts that play the square wave/, findings.first.message)
    assert_match(/plays:/, findings.first.message, "says how to have more parts")
  end

  def test_one_recorded_part_too_many_stops_the_build
    findings = detect([part, part, part(wave: :triangle), part(noise: true)] +
                      Array.new(TOO_MANY) { part(:organ) })

    assert_equal 1, findings.length
    assert_match(/#{TOO_MANY} parts that play an instrument/, findings.first.message)
    refute_match(/can play the square wave/, findings.first.message,
                 "every voice the console plays itself is taken, so none of them is a way out")
  end

  def test_a_song_with_square_wave_voices_to_spare_is_told_it_can_use_them
    message = detect(Array.new(TOO_MANY) { part(:organ) }).first.message

    assert_match(/One part can play the square wave/, message)
    assert_match(/remove `plays:` from it/, message)
  end

  # THE TWO VOICES THE CONSOLE PLAYS ITSELF COST NO MIXER VOICE, which is the thing an author
  # cannot work out and the reason to reach for them before a ninth recording.
  def test_a_song_out_of_mixer_voices_is_pointed_at_the_two_that_cost_none
    message = detect(Array.new(TOO_MANY) { part(:organ) }).first.message

    assert_match(/`plays: :wave`/, message)
    assert_match(/`plays: :noise`/, message)
    assert_match(/costs no mixer voice/, message)
  end

  def test_every_voice_used_and_no_more_is_quiet
    assert_empty detect([part, part, part(wave: :triangle), part(noise: true)] +
                        Array.new(RubyGBA::Sound::MIXER_VOICES) { part(:organ) })
  end

  # --- the console's own two voices, one each ---

  def test_a_second_part_on_the_wave_voice_stops_the_build
    findings = detect([part(wave: :triangle), part(wave: :sine)])

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/2 parts that play the wave voice/, findings.first.message)
    assert_match(/the console has 1 wave voice/, findings.first.message)
  end

  def test_a_second_part_on_the_noise_voice_stops_the_build
    findings = detect([part(noise: true), part(noise: true)])

    assert_equal 1, findings.length
    assert_match(/2 parts that play the noise voice/, findings.first.message)
    assert_match(/the console has 1 noise voice/, findings.first.message)
  end

  # A song can have one part on every voice there is, all at once — which is the whole of what
  # the two new lanes are for.
  def test_every_voice_at_once_is_quiet
    assert_empty detect([part, part, part(wave: :sawtooth), part(noise: true), part(:organ)])
  end

  # --- through the build, however the song was made ---

  def build(&program)
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("PARTS", code: "ZPRT", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        instrument :organ, pcm: [60, -60] * 400, rate: 8000, note: :C4
        instance_exec(&program)
        game_loop { wait_vblank }
      end
    end
    err.string
  end

  def test_a_song_block_meets_the_limit
    said = build do
      song :trio do
        voice(:a) { note :C4, :quarter }
        voice(:b) { note :E4, :quarter }
        voice(:c) { note :G4, :quarter }
      end
      play_song :trio
    end

    assert_match(/The song :trio has 3 parts that play the square wave/, said)
    assert_match(/voice :strings, plays: :strings/, said, "the fix is written the way a song block writes it")
  end

  def test_a_score_meets_the_same_limit
    chord = Array.new(TOO_MANY) { |n| Part.new(plays: :organ, notes: [Note.new(at: 0, key: 48 + n)]) }
    said = build { songs(:music, [RubyGBA::Score.new(parts: chord)]).play 0 }

    assert_match(/Song 0 of :music has #{TOO_MANY} parts that play an instrument/, said,
                 "a song from a list is named by its place in the list")
  end

  def test_a_score_is_shown_the_fix_the_way_a_score_writes_it
    trio = Array.new(3) { |n| Part.new(notes: [Note.new(at: 0, key: 60 + n)]) }
    said = build { songs(:music, [RubyGBA::Score.new(parts: trio)]).play 0 }

    assert_match(/Score::Part\.new\(plays: :strings/, said)
  end
end
