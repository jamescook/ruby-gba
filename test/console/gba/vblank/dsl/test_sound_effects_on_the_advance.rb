# frozen_string_literal: true

require "test_helper"

# The games these tests play and what the run's player says about them, kept once for the same
# games on the Advance's cartridge
# (test/lowering/gba/vblank/dsl/test_sound_effects_on_the_advance_cartridge.rb).
module SoundEffectsOnTheAdvanceGames
  include SharedConstants

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  SONG_PARTS = Ractor.make_shareable(Array.new(16) { |part| [:song, part] })

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame.
  private def every_ten_ticks(*keys, plays: nil, priority: 0, length: nil)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key, length: length) }
    Score.new(tempo: 150, priority: priority, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game with +effects+ as sound effects and, when given, +tune+ as the song it plays from its
  # first pass — or a list of them, the first played. The block runs each pass with the effects,
  # the pass number and the songs. Every game has a recording to play, :piano, four seconds long
  # at middle C, which the block can play as @piano.
  private def game(effects, tune: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      @piano = instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      music = songs :music, Array(tune) if tune
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        music&.play 0
        instance_exec(sfx, pass, music, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # What sounded on which frame, from the interpreter: [who, frequency] for each note, where a
  # frequency of 0 is a voice going quiet.
  private def notes_by_frame(program, frames)
    i = game_player
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).select { |entry| entry[0] == :note }.map { |entry| entry.drop(1) }
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # What the interpreter says the wave voice was set to on each frame it was: the waveform of the
  # note, or :silent.
  private def wave_notes_by_frame(program, frames)
    i = game_player
    shapes = {}
    i.each_vblank do |frame|
      i.audio.each do |kind, settings|
        shapes[frame] = settings[:shape] if kind == :wave
        shapes[frame] = :silent if kind == :stop_wave
      end
      i.audio.clear
    end
    i.run(program, frames: frames)
    shapes
  end

  # [frames since the first setting that was not 0, setting] for each change in +settings+, one
  # setting a frame.
  private def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  # A waveform as the number wave RAM holds for it, reading its four words in order.
  private def waveform(shape)
    VBlank::Audio::Sound::Registers.wavetable_halfwords(shape).each_slice(2).each_with_index.sum do |(low, high), word|
      (low | (high << 16)) << (32 * word)
    end
  end

  # [frames since the wave voice first sounded, waveform] for each change, from the interpreter:
  # the waveform of the last note on the voice.
  private def interpreted_waveforms(program, frames:)
    shapes = wave_notes_by_frame(program, frames).reject { |_, shape| shape == :silent }
    loaded = nil
    changes((1..frames).filter_map { |frame| (loaded = shapes.fetch(frame, loaded)) && waveform(loaded) })
  end

  # The game's own `wave` on pass 5, over a song on the triangle, in a game whose one effect plays
  # the wave voice.
  private def games_own_wave_over_a_song
    triangle = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :triangle)
    hit = every_ten_ticks(:C5, plays: :sawtooth)
    game([hit], tune: triangle) { |_sfx, pass| (pass == 5).then { wave :sine, :C5 } }
  end

  # A song whose +parts+ recorded parts each strike a note at each tick of +at+, at +priority+ —
  # held until the next unless it has a +length+, and shaped by +envelope+ when given.
  private def chord(parts, priority: 0, at: [0], length: nil, envelope: nil)
    notes = at.map { |tick| Note.new(at: tick, key: :C4, length: length) }
    Score.new(tempo: 150, priority: priority, length: 400,
              parts: Array.new(parts) { Part.new(plays: :piano, envelope: envelope, notes: notes) })
  end

  # One recorded note ranked at +priority+, asked for on pass 10.
  private def recorded_hit(priority, parts: 1)
    Score.new(tempo: 150, priority: priority, length: 30,
              parts: Array.new(parts) { Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C5)]) })
  end

  # An effect that plays a recording, two notes ten ticks apart, asked for on pass 3.
  private def recorded_effect_asked_for_once
    game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }
  end

  # RECORDED EFFECTS IN A GROUP: cut off, not played for a lower one, on a tie, and asked for
  # again — whose each mixer voice is, the same on both backends.
  private def long_recorded(key, priority)
    Score.new(tempo: 150, priority: priority, group: :voice,
              parts: [Part.new(plays: :piano, notes: [Note.new(at: 5, key: key, length: 60)])])
  end

  private def recorded_pair(first:, second:, asks: [0, 1])
    game([long_recorded(:C4, first), long_recorded(:E4, second)]) do |sfx, pass|
      (pass == 3).then { sfx.play asks.first }
      (pass == 14).then { sfx.play asks.last }
    end
  end

  # Each pair of recorded effects, and whose each mixer voice is the given frames in.
  private def recorded_pairs_and_owners
    cry_alone = [[:"sfx.0", 0]]
    hurt_alone = [[:"sfx.1", 0]]
    {
      recorded_pair(first: 64, second: 72) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 72, second: 64) => { 10 => cry_alone, 22 => cry_alone },
      recorded_pair(first: 64, second: 64) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 64, second: 72, asks: [0, 0]) => { 10 => cry_alone, 17 => [], 22 => cry_alone },
    }
  end

  # An effect filling every voice from pass 3, over a recorded song with a note every twenty ticks.
  private def effect_filling_the_mixer
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    game([recorded_hit(68, parts: 16)], tune: tune) { |sfx, pass| (pass == 3).then { sfx.play 0 } }
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end: each game,
  # whose each mixer voice is, and how many frames in.
  private def effect_voices_kept_and_let_go
    two_notes = every_ten_ticks(:C4, :E4, plays: :piano)
    restarted = game([two_notes]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }
    song_restarts = game([recorded_hit(68)], tune: chord(1)) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      (pass == 15).then { stop_music }
    end
    ended = game([two_notes]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }
    shaped = game([Score.new(tempo: 150, parts: [Part.new(plays: :piano, envelope: { release: 0.25 },
                                                          notes: [Note.new(at: 0, key: :C4, length: 20)])])]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
    end

    sounding = [[:"sfx.0", 0]]
    { restarted => sounding, song_restarts => [[:song, 0], [:"sfx.0", 0]], ended => [], shaped => sounding }
      .zip([12, 18, 40, 26]).map { |(program, owners), frames| [program, owners, frames] }
  end
end

# THE TESTS OF vblank/dsl/test_sound_effects.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A SCORE PLAYED ONCE, AS A SOUND EFFECT, OVER THE SONG THAT IS PLAYING.
#
# A sword hit, a door, a chest opening: each is a short run of notes decoded from somewhere the
# same way a tune is, and each plays over the room's music without stopping it. When the effect
# and the song want the same voice, the one with the higher priority sounds on it.
class TestSoundEffectsOnTheAdvance < Minitest::Test
  include SoundEffectsOnTheAdvanceGames

  # --- one effect on its own ---

  # The same Score named as a tune comes round, as any tune does: played as an effect it is walked
  # once as written, and played as a tune it is put right for coming round.
  def test_an_effect_named_as_a_tune_comes_round
    program = game([every_ten_ticks(:C5, :E5, length: 5)]) { |_sfx, pass| (pass == 1).then { play_song :"sfx.0" } }
    starts = notes_by_frame(program, 80).values.flatten(1).count([:"sfx.0", NOTES[:C5]])

    assert_operator starts, :>=, 2, "the tune plays its first note again each time it comes round"
  end

  # --- on the wave voice ---

  # The game's own `wave` puts its waveform in wave RAM too, so the song's next note puts the
  # song's back — in a game whose effects play the wave voice, whether or not one is playing.
  # (The console doing the same is in the cartridge's tests.)
  def test_the_songs_waveform_comes_back_after_the_games_own_wave
    want = interpreted_waveforms(games_own_wave_over_a_song, frames: 30)

    assert_equal %i[triangle sine triangle].map { |shape| waveform(shape) }, want.map(&:last)
  end

  # --- on the mixer ---

  # The voices sounding after +frames+, from the interpreter: whose each one is, and the recording
  # it plays.
  private def voices_after(program, frames)
    i = game_player.run(program, frames: frames)
    i.sound_owners.zip(i.active_samples)
  end

  # A part that plays a recording sounds each note on a voice of the mixer, which is the effect's.
  def test_an_effect_plays_a_recording_on_a_voice_of_its_own
    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(recorded_effect_asked_for_once, 8)
  end

  # Asked for again, its first note takes over the voice its last note was on, rather than a
  # second one.
  def test_an_effect_asked_for_again_keeps_its_one_voice
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 12)
  end

  # At its end the effect lets its voice go, although the recording has further to run...
  def test_an_effect_lets_its_voice_go_at_its_end
    program = recorded_effect_asked_for_once

    assert_equal [[:"sfx.0", NOTES[:E4]]], notes_by_frame(program, 40)[14]
    assert_equal [[:"sfx.0", 0]], notes_by_frame(program, 40)[38]
    assert_empty voices_after(program, 40)
  end

  # ...and a note with a shape falls away there instead of stopping.
  def test_a_shaped_effect_note_falls_away_at_its_end
    shaped = Score.new(tempo: 150, parts: [Part.new(plays: :piano, envelope: { release: 0.25 },
                                                    notes: [Note.new(at: 0, key: :C4, length: 20)])])
    program = game([shaped]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 26), "still falling away just after its end"
    assert_empty voices_after(program, 60), "and gone once it has"
  end

  # A note plays the recording at its own pitch, reading it faster for a higher note: two octaves
  # up, the four seconds last one.
  def test_an_effect_note_plays_its_recording_at_the_notes_pitch
    long_note = ->(key) { Score.new(tempo: 150, length: 200, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: key)])]) }
    at = ->(key) { game([long_note.call(key)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } } }

    assert_equal 1, voices_after(at.call(:C4), 80).size
    assert_empty voices_after(at.call(:C6), 80)
  end

  # --- sharing the mixer ---

  # Every voice holds the song, and the effect outranks it: the effect's note takes a voice from
  # the song — the first of them, since they all rank the same.
  def test_an_effect_note_takes_a_voice_from_a_song_it_outranks
    program = game([recorded_hit(68)], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 20).sound_owners
  end

  # The song outranks the effect: the effect's note is not played, and nothing of the song's is
  # touched.
  def test_an_effect_note_below_the_song_with_every_voice_busy_is_not_played
    program = game([recorded_hit(68)], tune: chord(16, priority: 80)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    i = game_player.run(program, frames: 20)

    assert_equal SONG_PARTS, i.sound_owners
    assert_includes i.audio, [:sound_effect, :"sfx.0"]
    refute_includes i.audio, [:note, :"sfx.0", NOTES[:C5]]
    assert_equal 1, i.sound_drops.dropped, "the profile counts the note that did not play"
  end

  # The other way round: an effect fills every voice, and the song's note under it is not played.
  # The song carries on in time, and is heard again from its next note once the effect is over.
  def test_a_song_note_below_an_effect_filling_every_voice_is_heard_from_its_next_note
    heard = notes_by_frame(effect_filling_the_mixer, 50)

    assert_equal [[:"music.0", NOTES[:C4]]], heard[2]
    refute heard.key?(22), "the song's second note is not played"
    assert_equal [[:"music.0", NOTES[:G4]]], heard[42]
  end

  # The game's own sounds rank below every song and effect, so they give way first.
  def test_an_effect_note_takes_the_games_own_sound_before_the_songs
    program = game([recorded_hit(68)], tune: chord(15)) do |sfx, pass|
      (pass == 1).then { @piano.play(:G4) }
      (pass == 10).then { sfx.play 0 }
    end
    i = game_player.run(program, frames: 20)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.take(15), i.sound_owners
  end

  # Every voice holds a song note that has ended and is fading away: the effect's note takes the
  # quietest of those, whoever's it is, rather than one ranked below it.
  def test_an_effect_note_takes_a_fading_note_first
    fading = chord(16, length: 8, envelope: { release: 1.0 })
    program = game([recorded_hit(68)], tune: fading) { |sfx, pass| (pass == 12).then { sfx.play 0 } }
    i = game_player.run(program, frames: 16)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), i.sound_owners
    assert_equal 0, i.sound_drops.dropped
  end

  # A song part that loses its voice to an effect is heard again from its next note.
  def test_a_song_part_that_loses_its_voice_has_one_again_at_its_next_note
    program = game([recorded_hit(68)], tune: chord(16, at: [0, 60])) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 30).sound_owners
    assert_equal SONG_PARTS, game_player.run(program, frames: 70).sound_owners
  end

  # A note at volume 0 sounds nothing, so on the mixer too it takes no voice and lets go of the
  # one its part had — the same as a rest.
  def test_a_silent_recorded_note_takes_no_voice
    quiet = Score.new(tempo: 150, priority: 68, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :D5, volume: 0),
    ])])
    program = game([quiet], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 15).sound_owners
    assert_equal SONG_PARTS.drop(1), game_player.run(program, frames: 25).sound_owners
  end

  # How many voices sounded at once counts an effect's, with no song playing.
  def test_the_most_voices_at_once_counts_an_effects
    program = game([recorded_hit(68, parts: 3)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal 3, game_player.run(program, frames: 10).peak_voices
  end

  # The song starting over lets go of its own voices and not the effect's.
  def test_starting_the_song_over_leaves_an_effects_recorded_note_alone
    program = game([recorded_hit(68)], tune: chord(1)) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      (pass == 15).then { stop_music }
    end

    assert_includes game_player.run(program, frames: 18).sound_owners, [:"sfx.0", 0]
  end

  # Whose each mixer voice is for an effect that plays a recording: the effect's own.
  def test_an_effects_recording_sounds_on_a_voice_the_effect_owns
    assert_equal [[:"sfx.0", 0]], game_player.run(recorded_effect_asked_for_once, frames: 8).sound_owners
  end

  # RECORDED EFFECTS IN A GROUP: whose each mixer voice is, frame by frame.
  def test_a_group_of_recorded_effects_decides_whose_each_voice_is
    recorded_pairs_and_owners.each do |program, moments|
      moments.each do |frames, owners|
        assert_equal owners, game_player.run(program, frames: frames).sound_owners, "#{frames} frames in"
      end
    end
  end

  # An effect filling every voice: the song's note under it is not played, and its next one is.
  def test_the_songs_next_note_has_a_voice_once_an_effect_filling_the_mixer_ends
    assert_equal [[:song, 0]], game_player.run(effect_filling_the_mixer, frames: 45).sound_owners
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end.
  def test_an_effects_voice_is_kept_and_let_go_through_restarts_and_ends
    effect_voices_kept_and_let_go.each do |program, owners, frames|
      assert_equal owners, game_player.run(program, frames: frames).sound_owners, "#{frames} frames in"
    end
  end

  # The console held to every one of these, and to who gives way on a full mixer, the volume an
  # effect plays at and the pitch it reads its recording at, is in
  # test/lowering/gba/vblank/dsl/test_sound_effects_on_the_advance_cartridge.rb.
end
