# frozen_string_literal: true

require "test_helper"

# A SCORE PLAYED ONCE, AS A SOUND EFFECT, OVER THE SONG THAT IS PLAYING.
#
# A sword hit, a door, a chest opening: each is a short run of notes decoded from somewhere the
# same way a tune is, and each plays over the room's music without stopping it. When the effect
# and the song want the same voice, the one with the higher priority sounds on it.
class TestSoundEffects < Minitest::Test
  Score = RubyGBA::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame.
  def every_ten_ticks(*keys, plays: nil, priority: 0, length: nil)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key, length: length) }
    Score.new(tempo: 150, priority: priority, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game with +effects+ as sound effects and, when given, +tune+ as the song it plays from its
  # first pass — or a list of them, the first played. The block runs each pass with the effects,
  # the pass number and the songs. Every game has a recording to play, :piano, four seconds long
  # at middle C, which the block can play as @piano.
  def game(effects, tune: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      @piano = instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      music = songs :music, Array(tune) if tune
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add 1
        music&.play 0
        instance_exec(sfx, pass, music, &body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  # What sounded on which frame, from the interpreter: [who, frequency] for each note, where a
  # frequency of 0 is a voice going quiet.
  def notes_by_frame(program, frames)
    i = Reference.new
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

  # --- one effect on its own ---

  # Asked for on pass 3, it starts on the frame after, the way a song does, plays each note once
  # and goes quiet at its end rather than coming round again.
  def test_an_effect_plays_once_from_the_frame_it_is_asked_for
    program = game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal({ 4 => [[:"sfx.0", NOTES[:C5]]], 14 => [[:"sfx.0", NOTES[:E5]]], 38 => [[:"sfx.0", 0]] },
                 notes_by_frame(program, 80))
  end

  # --- over the song, on the same voice ---

  # The song's one part sounds on frames 2, 22 and 42; the effect, on the same voice, from frame
  # 11 to its end on frame 40. Both play the first square voice, or both whatever +plays+ names —
  # the effect +effect_plays+, when that is given. The effect's part is quieter, and a thinner
  # tone, so the console can tell the two apart.
  def song_and_effect(song_priority:, effect_priority:, plays: nil, effect_plays: plays)
    tune = Score.new(tempo: 150, priority: song_priority, parts: [Part.new(plays: plays, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: effect_priority, parts: [Part.new(plays: effect_plays, volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5),
    ])])
    game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
  end

  # The effect outranks the song: the song's note on frame 22 is never heard, and the part comes
  # back with its next note once the effect has let the voice go — not with the one it lost.
  def test_an_effect_of_higher_priority_takes_the_voice_until_it_ends
    heard = notes_by_frame(song_and_effect(song_priority: 0, effect_priority: 68), 50)

    assert_equal({ 2 => [[:"music.0", NOTES[:C4]]], 11 => [[:"sfx.0", NOTES[:C5]]],
                   16 => [[:"sfx.0", NOTES[:D5]]], 40 => [[:"sfx.0", 0]], 42 => [[:"music.0", NOTES[:G4]]] },
                 heard)
  end

  # The song outranks the effect: the effect plays nothing on that voice, and the song is heard
  # throughout.
  def test_an_effect_of_lower_priority_is_silent_on_a_voice_the_song_holds
    heard = notes_by_frame(song_and_effect(song_priority: 80, effect_priority: 68), 50)

    assert_equal({ 2 => [[:"music.0", NOTES[:C4]]], 22 => [[:"music.0", NOTES[:E4]]],
                   42 => [[:"music.0", NOTES[:G4]]] }, heard)
  end

  # Nothing said about priority on either, and the effect is heard: a sound effect played over a
  # song is meant to be.
  def test_on_a_tie_the_effect_takes_the_voice
    heard = notes_by_frame(song_and_effect(song_priority: 0, effect_priority: 0), 50)

    assert_equal [[:"sfx.0", NOTES[:C5]]], heard[11]
    refute heard.key?(22), "the song's note is not heard while the effect sounds"
  end

  # On a frame where the song and an effect it outranks both start a note on a free voice, only
  # the song's is played: a note that loses its voice on the frame it starts is never written.
  def test_a_note_that_loses_its_voice_on_the_frame_it_starts_is_never_played
    tune = Score.new(tempo: 150, priority: 50, parts: [Part.new(notes: [
      Note.new(at: 0, key: :C4, length: 10), Note.new(at: 20, key: :E4),
    ])])
    program = game([every_ten_ticks(:C5, priority: 20), every_ten_ticks(:G5, priority: 90)], tune: tune) do |sfx, pass|
      (pass == 21).then { sfx.play 0 }
    end

    assert_equal [[:"music.0", NOTES[:E4]]], notes_by_frame(program, 30)[22]
  end

  # A note at volume 0 sounds nothing, so it lets the voice go the way a rest does: the song's note
  # on frame 22 is heard, on both backends.
  def test_a_silent_note_lets_the_voice_go
    tune = Score.new(tempo: 150, parts: [Part.new(notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5, volume: 0),
    ])])
    program = game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"music.0", NOTES[:E4]]], notes_by_frame(program, 30)[22]
    assert_includes console_changes(program, SQUARE_1, frames: 40), [20, square_setting(:half, 12)],
                    "the console plays the song's note 20 frames after its first"
  end

  # --- on the wave voice ---

  # The wave voice is shared by the same rule: the effect's sawtooth takes it from the song's
  # triangle, and the song comes back with its next note.
  def test_an_effect_of_higher_priority_takes_the_wave_voice_until_it_ends
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :triangle, effect_plays: :sawtooth)

    assert_equal({ 2 => [[:"music.0", NOTES[:C4]]], 11 => [[:"sfx.0", NOTES[:C5]]],
                   16 => [[:"sfx.0", NOTES[:D5]]], 40 => [[:"sfx.0", 0]], 42 => [[:"music.0", NOTES[:G4]]] },
                 notes_by_frame(program, 50))
  end

  # ...and each note sounds in its own player's waveform: the sawtooth while the effect holds the
  # voice, silence at its end, and the triangle again after.
  def test_a_note_on_the_wave_voice_sounds_in_its_own_waveform
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :triangle, effect_plays: :sawtooth)

    assert_equal({ 2 => :triangle, 11 => :sawtooth, 16 => :sawtooth, 40 => :silent, 42 => :triangle },
                 wave_notes_by_frame(program, 50))
  end

  # What the interpreter says the wave voice was set to on each frame it was: the waveform of the
  # note, or :silent.
  def wave_notes_by_frame(program, frames)
    i = Reference.new
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

  # The wave voice has five volumes, and the nearest to 1 of 15 is none: that note is silent, so it
  # lets the voice go, and the song's note on frame 22 is heard.
  def test_a_note_too_quiet_for_the_wave_voice_lets_it_go
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :triangle, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: :sawtooth, volume: 9, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5, volume: 1),
    ])])
    program = game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"music.0", NOTES[:E4]]], notes_by_frame(program, 30)[22]
    assert_backends_share_the_voice(program, WAVE_TONES, channel: 3)
  end

  # --- asked for again, and several at once ---

  # Asked for again while it sounds, it starts again from its first note — it does not play twice
  # over itself, and it does not wait to finish.
  def test_an_effect_asked_for_again_starts_again_from_its_first_note
    program = game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }

    assert_equal({ 4 => [[:"sfx.0", NOTES[:C5]]], 9 => [[:"sfx.0", NOTES[:C5]]], 19 => [[:"sfx.0", NOTES[:E5]]],
                   43 => [[:"sfx.0", 0]] }, notes_by_frame(program, 80))
  end

  # Two effects on two voices sound together, each on its own.
  def test_two_effects_on_different_voices_sound_together
    drums = every_ten_ticks(:C3, plays: :noise)
    program = game([every_ten_ticks(:C5), drums]) do |sfx, pass|
      (pass == 3).then do
        sfx.play 0
        sfx.play 1
      end
    end

    assert_equal [[:"sfx.0", NOTES[:C5]], [:"sfx.1", NOTES[:C3]]], notes_by_frame(program, 10)[4]
  end

  # Two effects on one voice: the higher priority sounds, whichever was asked for first — and on a
  # tie, the one declared first.
  def test_of_two_effects_on_one_voice_the_higher_priority_sounds
    heard_when_both_start = lambda do |low_priority|
      program = game([every_ten_ticks(:C5, priority: low_priority), every_ten_ticks(:E5, priority: 50)]) do |sfx, pass|
        (pass == 3).then do
          sfx.play 1
          sfx.play 0
        end
      end
      notes_by_frame(program, 10)[4]
    end

    assert_equal [[:"sfx.1", NOTES[:E5]]], heard_when_both_start.call(10)
    assert_equal [[:"sfx.0", NOTES[:C5]]], heard_when_both_start.call(90)
    assert_equal [[:"sfx.0", NOTES[:C5]]], heard_when_both_start.call(50), "a tie goes to the effect declared first"
  end

  # --- on the mixer ---

  # The voices sounding after +frames+, from the interpreter: whose each one is, and the recording
  # it plays.
  def voices_after(program, frames)
    i = Reference.new.run(program, frames: frames)
    i.sound_owners.zip(i.active_samples)
  end

  # A part that plays a recording sounds each note on a voice of the mixer, which is the effect's.
  def test_an_effect_plays_a_recording_on_a_voice_of_its_own
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 8)
  end

  # Asked for again, its first note takes over the voice its last note was on, rather than a
  # second one.
  def test_an_effect_asked_for_again_keeps_its_one_voice
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 12)
  end

  # At its end the effect lets its voice go, although the recording has further to run...
  def test_an_effect_lets_its_voice_go_at_its_end
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

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

  # A song whose +parts+ recorded parts each strike a note at each tick of +at+, at +priority+ —
  # held until the next unless it has a +length+, and shaped by +envelope+ when given.
  def chord(parts, priority: 0, at: [0], length: nil, envelope: nil)
    notes = at.map { |tick| Note.new(at: tick, key: :C4, length: length) }
    Score.new(tempo: 150, priority: priority, length: 400,
              parts: Array.new(parts) { Part.new(plays: :piano, envelope: envelope, notes: notes) })
  end

  # One recorded note ranked at +priority+, asked for on pass 10.
  def recorded_hit(priority, parts: 1)
    Score.new(tempo: 150, priority: priority, length: 30,
              parts: Array.new(parts) { Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C5)]) })
  end

  SONG_PARTS = Array.new(16) { |part| [:song, part] }.freeze

  # Every voice holds the song, and the effect outranks it: the effect's note takes a voice from
  # the song — the first of them, since they all rank the same.
  def test_an_effect_note_takes_a_voice_from_a_song_it_outranks
    program = game([recorded_hit(68)], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), Reference.new.run(program, frames: 20).sound_owners
  end

  # The song outranks the effect: the effect's note is not played, and nothing of the song's is
  # touched.
  def test_an_effect_note_below_the_song_with_every_voice_busy_is_not_played
    program = game([recorded_hit(68)], tune: chord(16, priority: 80)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    i = Reference.new.run(program, frames: 20)

    assert_equal SONG_PARTS, i.sound_owners
    assert_includes i.audio, [:sound_effect, :"sfx.0"]
    refute_includes i.audio, [:note, :"sfx.0", NOTES[:C5]]
    assert_equal 1, i.sound_drops.dropped, "the profile counts the note that did not play"
  end

  # The other way round: an effect fills every voice, and the song's note under it is not played.
  # The song carries on in time, and is heard again from its next note once the effect is over.
  def test_a_song_note_below_an_effect_filling_every_voice_is_heard_from_its_next_note
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    program = game([recorded_hit(68, parts: 16)], tune: tune) { |sfx, pass| (pass == 3).then { sfx.play 0 } }
    heard = notes_by_frame(program, 50)

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
    i = Reference.new.run(program, frames: 20)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.take(15), i.sound_owners
  end

  # Every voice holds a song note that has ended and is fading away: the effect's note takes the
  # quietest of those, whoever's it is, rather than one ranked below it.
  def test_an_effect_note_takes_a_fading_note_first
    fading = chord(16, length: 8, envelope: { release: 1.0 })
    program = game([recorded_hit(68)], tune: fading) { |sfx, pass| (pass == 12).then { sfx.play 0 } }
    i = Reference.new.run(program, frames: 16)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), i.sound_owners
    assert_equal 0, i.sound_drops.dropped
  end

  # A song part that loses its voice to an effect is heard again from its next note.
  def test_a_song_part_that_loses_its_voice_has_one_again_at_its_next_note
    program = game([recorded_hit(68)], tune: chord(16, at: [0, 60])) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), Reference.new.run(program, frames: 30).sound_owners
    assert_equal SONG_PARTS, Reference.new.run(program, frames: 70).sound_owners
  end

  # A note at volume 0 sounds nothing, so on the mixer too it takes no voice and lets go of the
  # one its part had — the same as a rest.
  def test_a_silent_recorded_note_takes_no_voice
    quiet = Score.new(tempo: 150, priority: 68, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :D5, volume: 0),
    ])])
    program = game([quiet], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), Reference.new.run(program, frames: 15).sound_owners
    assert_equal SONG_PARTS.drop(1), Reference.new.run(program, frames: 25).sound_owners
  end

  # How many voices sounded at once counts an effect's, with no song playing.
  def test_the_most_voices_at_once_counts_an_effects
    program = game([recorded_hit(68, parts: 3)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal 3, Reference.new.run(program, frames: 10).peak_voices
  end

  # The song starting over lets go of its own voices and not the effect's.
  def test_starting_the_song_over_leaves_an_effects_recorded_note_alone
    program = game([recorded_hit(68)], tune: chord(1)) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      (pass == 15).then { stop_music }
    end

    assert_includes Reference.new.run(program, frames: 18).sound_owners, [:"sfx.0", 0]
  end

  # --- one at a time, in a group ---

  # A CRY on the first square voice, three notes ten ticks apart, and a HURT on the noise voice
  # — different voices, so without a group the two would sound together.
  def cry(priority, group: :voice)
    Score.new(tempo: 150, priority: priority, group: group,
              parts: [Part.new(notes: %i[C5 E5 G5].each_with_index.map { |key, n| Note.new(at: n * 10, key: key) })])
  end

  def hurt(priority, group: :voice)
    Score.new(tempo: 150, priority: priority, group: group,
              parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: :C3, length: 30)])])
  end

  # The cry asked for on pass 3, and the hurt on pass 8.
  def cry_then_hurt(cry_priority:, hurt_priority:, group: :voice)
    game([cry(cry_priority, group: group), hurt(hurt_priority, group: group)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 1 }
    end
  end

  # Asked for while another of its group sounds, at a priority at least as high, an effect cuts
  # that one off: its voice goes quiet, and its later notes are never heard.
  def test_an_effect_cuts_off_the_one_its_group_is_playing
    heard = notes_by_frame(cry_then_hurt(cry_priority: 64, hurt_priority: 72), 40)

    assert_equal [[:"sfx.0", NOTES[:C5]]], heard[4]
    assert_equal [[:"sfx.1", NOTES[:C3]], [:"sfx.0", 0]], heard[9], "the hurt starts, and the cry goes quiet"
    refute heard.key?(14), "the cry's second note is not heard"
  end

  # At a lower priority it is not played at all, and the one sounding carries on.
  def test_an_effect_below_the_one_its_group_is_playing_is_not_played
    i = Reference.new.run(cry_then_hurt(cry_priority: 72, hurt_priority: 64), frames: 40)

    assert_equal 1, i.audio.count { |entry| entry[0] == :sound_effect }, "only the cry started"
    assert_includes i.audio, [:note, :"sfx.0", NOTES[:G5]]
    refute(i.audio.any? { |entry| entry[0] == :note && entry[1] == :"sfx.1" })
  end

  # A tie cuts off the one sounding: the effect asked for is the one the game wants now.
  def test_an_effect_as_high_as_the_one_its_group_is_playing_cuts_it_off
    heard = notes_by_frame(cry_then_hurt(cry_priority: 64, hurt_priority: 64), 40)

    assert_includes heard[9], [:"sfx.1", NOTES[:C3]]
    refute heard.key?(14)
  end

  # Effects in different groups, or in none, sound together.
  def test_effects_in_different_groups_sound_together
    apart = notes_by_frame(game([cry(72, group: :voice), hurt(64, group: :sword)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 1 }
    end, 40)
    ungrouped = notes_by_frame(cry_then_hurt(cry_priority: 72, hurt_priority: 64, group: nil), 40)

    [apart, ungrouped].each do |heard|
      assert_equal [[:"sfx.1", NOTES[:C3]]], heard[9]
      assert_equal [[:"sfx.0", NOTES[:E5]]], heard[14]
    end
  end

  # Asked for again while it sounds, an effect in a group stops before it starts again: its voice
  # goes quiet on that frame, the same as the one it would cut off.
  def test_an_effect_in_a_group_asked_for_again_stops_first
    program = game([cry(64)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }

    assert_equal [[:"sfx.0", 0], [:"sfx.0", NOTES[:C5]]], notes_by_frame(program, 20)[9]
  end

  # Asked for again, an effect is still its group's one, so a lower one asked for after it on the
  # same pass is not played — whether or not it was already sounding.
  def test_an_effect_asked_for_again_still_holds_its_group_against_a_lower_one
    sounding = game([cry(72), hurt(64)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 0; sfx.play 1 }
    end
    twice = game([cry(72), hurt(64)]) { |sfx, pass| (pass == 3).then { sfx.play 0; sfx.play 0; sfx.play 1 } }

    [sounding, twice].each do |program|
      i = Reference.new.run(program, frames: 20)
      refute_includes i.audio, [:sound_effect, :"sfx.1"]
    end
  end

  # Two of a group asked for on one pass: the higher priority starts, whichever was asked first.
  def test_of_two_asked_for_together_in_a_group_the_higher_priority_starts
    [[1, 0], [0, 1]].each do |order|
      program = game([cry(64), hurt(72)]) { |sfx, pass| (pass == 3).then { order.each { |which| sfx.play which } } }
      i = Reference.new.run(program, frames: 10)

      assert_equal [[:sound_effect, :"sfx.1"]], i.audio.select { |entry| entry[0] == :sound_effect }, order.inspect
    end
  end

  # --- picked by name, or by a number the game works out ---

  def test_an_effect_is_played_by_name
    program = game({ hit: every_ten_ticks(:C5), spark: every_ten_ticks(:E5) }) do |sfx, pass|
      (pass == 3).then { sfx.play :spark }
    end

    assert_equal [[:"sfx.spark", NOTES[:E5]]], notes_by_frame(program, 10)[4]
  end

  def test_the_effect_played_is_the_one_a_number_names_and_a_number_naming_none_plays_nothing
    program = game([every_ten_ticks(:C5), every_ten_ticks(:E5)]) do |sfx, pass|
      which = var :which, 1
      (pass == 3).then { sfx.play which }
      (pass == 4).then { which.set 7 }
      (pass == 5).then { sfx.play which }
    end

    assert_equal({ 4 => [[:"sfx.1", NOTES[:E5]]], 28 => [[:"sfx.1", 0]] }, notes_by_frame(program, 40))
  end

  # WHICH EFFECT STARTED ON WHICH FRAME, which a game's own test reads without an emulator — the
  # sound of a hit belongs to the frame of the hit.
  def test_the_log_says_which_effect_started_on_which_frame
    program = game({ hit: every_ten_ticks(:C5), spark: every_ten_ticks(:E5) }) do |sfx, pass|
      (pass == 3).then { sfx.play :hit }
      (pass == 4).then { sfx.play :spark }
    end
    started = {}
    i = Reference.new
    i.each_vblank { |frame| i.audio.select { |entry| entry[0] == :sound_effect }.each { |entry| started[entry[1]] ||= frame } }
    i.run(program, frames: 10)

    assert_equal({ "sfx.hit": 4, "sfx.spark": 5 }, started)
  end

  # --- the song around an effect ---

  # A song that stops, or starts over, leaves the voice an effect holds alone: the tune stopped on
  # pass 6 and named again on pass 7 starts over, and does not get the voice back while the
  # effect sounds.
  def test_starting_the_song_over_does_not_cut_an_effect_off
    tune = every_ten_ticks(:C4, :E4, :G4)
    program = game([every_ten_ticks(:C5, :E5, priority: 68)], tune: tune) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 6).then { stop_music }
    end
    heard = notes_by_frame(program, 20)

    assert_equal({ 2 => [[:"music.0", NOTES[:C4]]], 4 => [[:"sfx.0", NOTES[:C5]]], 14 => [[:"sfx.0", NOTES[:E5]]] },
                 heard)
  end

  # Moving the music volume sets the song's held notes again — never on a voice an effect has
  # taken, whose note is the effect's, at the effect's own volume.
  def test_the_music_volume_does_not_reach_a_voice_an_effect_holds
    tune = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])], length: 200)
    program = game([every_ten_ticks(:C5, :E5)], tune: tune) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 6).then { music_volume 50 }
    end
    i = Reference.new.run(program, frames: 20)
    after = i.audio.drop_while { |entry| entry != [:sound_effect, :"sfx.0"] }

    assert_empty after.select { |entry| entry[0] == :loudness }, "nothing set the effect's voice to a music volume"
  end

  # --- the console ---

  # What a voice is set to that reads back: its volume, and a square voice's tone. Its pitch is
  # written with the bit that starts the note and does not read back, so the effect's part is
  # told from the song's by being quieter and thinner.
  SETTING = 0xF0C0

  SQUARE_1 = RubyGBA::Constants::REG_SOUND1CNT_H
  NOISE = RubyGBA::Constants::REG_SOUND4CNT_L

  # How a voice was set on the console: [frames since it first sounded, setting] for each change.
  def console_changes(program, register, frames:)
    changes(console_readings(program, frames: frames) { |probe| probe.read32(register) & SETTING })
  end

  # What the block reads from the console after each of +frames+ frames.
  def console_readings(program, frames:)
    rom = assemble_rom(program, name: "SFXVOICE")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sfx.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      readings = Array.new(frames) do
        probe.step(1)
        yield probe
      end
      probe.close
      readings
    end
  end

  # The same, from what the interpreter logs each voice was set to: a note's volume and the tone of
  # the part that played it (+tones+, by who; none on the noise voice), or 0 for a voice going
  # quiet. The two start counting at different moments, so both count from the first sound.
  def interpreted_changes(program, channel, tones, frames:)
    i = Reference.new
    set = {}
    i.each_vblank do |frame|
      i.audio.select { |entry| entry[0] == :voice && entry[1] == channel }.each { |entry| set[frame] = entry }
      i.audio.clear
    end
    i.run(program, frames: frames)
    current = 0
    changes((1..frames).map do |frame|
      _, _, who, frequency, volume = set[frame]
      if who
        tone = tones.fetch(who)
        current = frequency.zero? ? 0 : setting(tone.is_a?(Hash) ? tone.fetch(channel) : tone, volume)
      end
      current
    end)
  end

  def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  REGISTERS = { 1 => SQUARE_1, 2 => RubyGBA::Constants::REG_SOUND2CNT_L, 3 => RubyGBA::Constants::REG_SOUND3CNT_H,
                4 => NOISE }.freeze

  # The two backends agree about when a voice changed and what it changed to, from the first sound
  # the interpreter heard to its last — the console runs on a little, since it starts later.
  def assert_backends_share_the_voice(program, tones, channel: 1)
    want = interpreted_changes(program, channel, tones, frames: 60)
    got = console_changes(program, REGISTERS.fetch(channel), frames: 75).take_while { |frame, _| frame <= 56 }

    assert_equal want.take_while { |frame, _| frame <= 56 }, got, "the voice numbered #{channel}"
  end

  # A voice's setting that reads back: a square voice's tone, and the volume — or for a +tone+ of
  # :wave, the nearest of the wave voice's five volumes.
  def self.setting(tone, volume)
    return RubyGBA::Sound::Registers::WAVE_VOLUMES.fetch(RubyGBA::Sound::Registers.wave_level(volume)) if tone == :wave

    ((tone ? RubyGBA::Sound::Registers.duty_bits(tone) : 0) << 6) | (volume << 12)
  end
  def setting(tone, volume) = self.class.setting(tone, volume)
  def square_setting(tone, volume) = setting(tone, volume)

  SONG_TONES = { "music.0": :half, "sfx.0": :quarter }.freeze
  SONG_SETTING = { "music.0": setting(:half, 12), "sfx.0": setting(:quarter, 9) }.freeze

  # THE TWO BACKENDS AGREE ABOUT WHO SOUNDED ON A SHARED VOICE, and when, one way round and the
  # other: the effect taking the first square voice and the song coming back after it, and the
  # song keeping it against an effect it outranks.
  def test_the_console_shares_a_square_voice_the_way_the_interpreter_does
    taken = song_and_effect(song_priority: 0, effect_priority: 68)

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [38, 0], [40, SONG_SETTING[:"music.0"]]],
                 interpreted_changes(taken, 1, SONG_TONES, frames: 60)
    assert_backends_share_the_voice(taken, SONG_TONES)
    assert_backends_share_the_voice(song_and_effect(song_priority: 80, effect_priority: 68), SONG_TONES)
    assert_backends_share_the_voice(song_and_effect(song_priority: 0, effect_priority: 0), SONG_TONES) # a tie
  end

  def test_the_console_shares_the_noise_voice_the_way_the_interpreter_does
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :noise)
    tones = { "music.0": nil, "sfx.0": nil }

    assert_equal [12 << 12, 9 << 12, 0, 12 << 12], interpreted_changes(program, 4, tones, frames: 60).map(&:last),
                 "the effect takes the voice, is silenced at its end, and the song comes back"
    assert_backends_share_the_voice(program, tones, channel: 4)
  end

  WAVE_TONES = { "music.0": :wave, "sfx.0": :wave }.freeze

  def test_the_console_shares_the_wave_voice_the_way_the_interpreter_does
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :triangle, effect_plays: :sawtooth)

    assert_equal [setting(:wave, 12), setting(:wave, 9), 0, setting(:wave, 12)],
                 interpreted_changes(program, 3, WAVE_TONES, frames: 60).map(&:last),
                 "the effect takes the voice, is silenced at its end, and the song comes back"
    assert_backends_share_the_voice(program, WAVE_TONES, channel: 3)
  end

  # THE WAVEFORM ON THE CONSOLE. The wave voice loops whatever waveform is in wave RAM, and there
  # is room there for one, so an effect's note has to put its own there — and the song's note after
  # it has to put the song's back.
  #
  # A tune on the triangle with a note every ten frames; an effect on the sawtooth from pass 10,
  # twelve frames long; and from pass 16 a second tune, on the sine, which starts while the effect
  # holds the voice. Its first note is lost to the effect, and its second is heard in the sine.
  #
  # The effect opens with a rest, which loads nothing, and a note too quiet to hear, which loads
  # the sawtooth all the same — a note, heard or not, is in its own waveform.
  def test_the_console_loads_the_waveform_of_each_note
    triangle = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :triangle)
    sine = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :sine)
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: :sawtooth, volume: 9, notes: [
      Note.new(at: 0, key: nil), Note.new(at: 2, key: :C5, volume: 1), Note.new(at: 4, key: :C5, length: 8),
    ])])
    program = game([hit], tune: [triangle, sine]) do |sfx, pass, music|
      (pass == 10).then { sfx.play 0 }
      (pass >= 16).then { music.play 1 }
    end
    want = interpreted_waveforms(program, frames: 40)

    assert_equal [[0, waveform(:triangle)], [11, waveform(:sawtooth)], [25, waveform(:sine)]], want
    assert_equal want, console_waveforms(program, frames: 50).take_while { |frame, _| frame <= 36 }
  end

  # The game's own `wave` puts its waveform in wave RAM too, so the song's next note puts the
  # song's back — in a game whose effects play the wave voice, whether or not one is playing. The
  # game's own sound is compared by its place in the order only: the game's code and the player
  # count their frames from different moments, so it lands a frame apart on the two backends.
  def test_the_console_loads_the_songs_waveform_again_after_the_games_own_wave
    triangle = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :triangle)
    hit = every_ten_ticks(:C5, plays: :sawtooth)
    program = game([hit], tune: triangle) { |_sfx, pass| (pass == 5).then { wave :sine, :C5 } }
    want = interpreted_waveforms(program, frames: 30)
    got = console_waveforms(program, frames: 40).take_while { |frame, _| frame <= 26 }

    assert_equal %i[triangle sine triangle].map { |shape| waveform(shape) }, want.map(&:last)
    assert_equal want.map(&:last), got.map(&:last)
    assert_equal want.last, got.last, "the song's note puts the triangle back on the same frame"
  end

  # A waveform as the number wave RAM holds for it, reading its four words in order.
  def waveform(shape)
    RubyGBA::Sound::Registers.wavetable_halfwords(shape).each_slice(2).each_with_index.sum do |(low, high), word|
      (low | (high << 16)) << (32 * word)
    end
  end

  # [frames since the wave voice first sounded, waveform] for each change, from the interpreter:
  # the waveform of the last note on the voice.
  def interpreted_waveforms(program, frames:)
    shapes = wave_notes_by_frame(program, frames).reject { |_, shape| shape == :silent }
    loaded = nil
    changes((1..frames).filter_map { |frame| (loaded = shapes.fetch(frame, loaded)) && waveform(loaded) })
  end

  # ...and from the console, reading wave RAM once a frame from the frame the voice first sounds.
  def console_waveforms(program, frames:)
    readings = console_readings(program, frames: frames) do |probe|
      ram = (0...4).sum { |word| probe.read32(RubyGBA::Constants::REG_WAVE_RAM + (word * 4)) << (32 * word) }
      [probe.read32(REGISTERS.fetch(3)) & SETTING, ram]
    end
    changes(readings.drop_while { |setting, _| setting.zero? }.map(&:last))
  end

  # THE HIT'S SHAPE: an effect on a square voice and the noise voice at once, over a song on both.
  def test_the_console_shares_a_square_voice_and_the_noise_voice_at_once
    notes = [Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4)]
    tune = Score.new(tempo: 150, parts: [Part.new(notes: notes), Part.new(plays: :noise, notes: notes)])
    hit_notes = [Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5)]
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(volume: 9, duty: :quarter, notes: hit_notes),
                                                      Part.new(plays: :noise, volume: 9, notes: hit_notes)])
    program = game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_backends_share_the_voice(program, SONG_TONES)
    assert_backends_share_the_voice(program, { "music.0": nil, "sfx.0": nil }, channel: 4)
  end

  # A SONG RANKED BETWEEN TWO EFFECTS, so the player walks the effects above it before the song's
  # parts and the one below it after them. The higher one takes the first square voice from the
  # song; the lower one, asked for while that is sounding, is silent there and heard on the second
  # square voice, which nobody else wants.
  def test_the_console_plays_effects_on_both_sides_of_the_songs_rank
    tune = Score.new(tempo: 150, priority: 50, parts: [Part.new(notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    high = Score.new(tempo: 150, priority: 90, parts: [Part.new(volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5),
    ])])
    low = Score.new(tempo: 150, priority: 20, parts: [
      Part.new(volume: 5, duty: :eighth, notes: [Note.new(at: 0, key: :C5)]),
      Part.new(volume: 7, duty: :three_quarter, notes: [Note.new(at: 0, key: :E5)]),
    ])
    program = game([high, low], tune: tune) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      (pass == 20).then { sfx.play 1 }
    end
    tones = { "music.0": :half, "sfx.0": :quarter, "sfx.1": { 1 => :eighth, 2 => :three_quarter } }

    assert_equal [[0, setting(:three_quarter, 7)], [24, 0]], interpreted_changes(program, 2, tones, frames: 60)
    assert_backends_share_the_voice(program, tones)
    assert_backends_share_the_voice(program, tones, channel: 2)
  end

  # With no song at all, and asked for twice so it starts again.
  def test_the_console_plays_an_effect_once_and_starts_it_again
    program = game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }
    tones = { "sfx.0": :half }

    assert_equal [[0, setting(:half, 12)], [39, 0]], interpreted_changes(program, 1, tones, frames: 60)
    assert_backends_share_the_voice(program, tones)
  end

  # By a number the game works out, turned into its place in the table: the quieter of the two,
  # and then nothing for a number naming no effect.
  def test_the_console_plays_the_effect_a_number_names
    quiet = Score.new(tempo: 150, parts: [Part.new(volume: 5, notes: [Note.new(at: 0, key: :C5)])])
    loud = Score.new(tempo: 150, priority: 90, parts: [Part.new(volume: 9, notes: [Note.new(at: 0, key: :C5)])])
    program = game([loud, quiet]) do |sfx, pass|
      which = var :which, 1
      (pass == 3).then { sfx.play which }
      (pass == 40).then { which.set 2 }
      (pass == 41).then { sfx.play which }
    end
    tones = { "sfx.0": :half, "sfx.1": :half }

    assert_equal [[0, setting(:half, 5)], [24, 0]], interpreted_changes(program, 1, tones, frames: 60)
    assert_backends_share_the_voice(program, tones)
  end

  # Two effects on one voice, of one priority, asked for on one frame: the one declared first.
  def test_the_console_breaks_a_tie_between_effects_the_way_the_interpreter_does
    first = Score.new(tempo: 150, parts: [Part.new(volume: 5, notes: [Note.new(at: 0, key: :C5)])])
    second = Score.new(tempo: 150, parts: [Part.new(volume: 9, notes: [Note.new(at: 0, key: :C5), Note.new(at: 30, key: :E5)])])
    program = game([first, second]) do |sfx, pass|
      (pass == 3).then do
        sfx.play 1
        sfx.play 0
      end
    end
    tones = { "sfx.0": :half, "sfx.1": :half }

    assert_equal [[0, setting(:half, 5)], [24, 0], [30, setting(:half, 9)], [54, 0]],
                 interpreted_changes(program, 1, tones, frames: 60)
    assert_backends_share_the_voice(program, tones)
  end

  # A song holding one long note, and an effect over it from pass 10, on the voice +plays+ and
  # +effect_plays+ name; the block says what else the game does on each pass.
  def long_note_under_an_effect(plays: nil, effect_plays: nil, &body)
    tune = Score.new(tempo: 150, length: 200, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C4)])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: effect_plays, volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :E5),
    ])])
    game([hit], tune: tune) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      instance_exec(pass, &body)
    end
  end

  # The song starting over while an effect sounds leaves the effect's voice alone on the console
  # too.
  def test_the_console_keeps_an_effects_voice_when_the_song_starts_over
    program = long_note_under_an_effect { |pass| (pass == 15).then { stop_music } }

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [43, 0]],
                 interpreted_changes(program, 1, SONG_TONES, frames: 60)
    assert_backends_share_the_voice(program, SONG_TONES)
  end

  # ...and a music volume moving while an effect sounds does not start the song's lost note again
  # over it, then or after the effect ends.
  def test_the_console_keeps_an_effects_voice_when_the_music_volume_moves
    program = long_note_under_an_effect { |pass| (pass == 20).then { music_volume 50 } }

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [43, 0]],
                 interpreted_changes(program, 1, SONG_TONES, frames: 60)
    assert_backends_share_the_voice(program, SONG_TONES)
  end

  # ...and the same on the wave voice, whose held note takes a new volume without starting again.
  def test_the_console_keeps_an_effects_wave_voice_when_the_music_volume_moves
    program = long_note_under_an_effect(plays: :triangle, effect_plays: :sawtooth) do |pass|
      (pass == 20).then { music_volume 50 }
    end

    assert_equal [[0, setting(:wave, 12)], [9, setting(:wave, 9)], [43, 0]],
                 interpreted_changes(program, 3, WAVE_TONES, frames: 60)
    assert_backends_share_the_voice(program, WAVE_TONES, channel: 3)
  end

  # --- the console's mixer ---

  # Whose each sounding voice is, +frames+ in, on each backend — the console run a little longer,
  # since it starts later. Every program here holds its voices steady for longer than that.
  def owners_on_both(program, frames:)
    [Reference.new.run(program, frames: frames).sound_owners, console_voices(program, frames: frames).map(&:owner)]
  end

  def console_voices(program, frames:) = console_run(program, frames: frames).voices

  def console_run(program, frames:) = assert_emulator_loads_rom(assemble_rom(program, name: "SFXMIX"), frames: frames + 2)

  def test_the_console_plays_an_effects_recording_on_a_voice_of_its_own
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }
    interpreted, console = owners_on_both(program, frames: 8)

    assert_equal [[:"sfx.0", 0]], interpreted
    assert_equal interpreted, console
  end

  # WHO GIVES WAY ON A FULL MIXER, on both backends: an effect over the song, a song over an
  # effect, and the game's own sound going first.
  def test_the_console_gives_a_voice_to_the_higher_rank_the_way_the_interpreter_does
    over = game([recorded_hit(68)], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    under = game([recorded_hit(68)], tune: chord(16, priority: 80)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    game_first = game([recorded_hit(68)], tune: chord(15)) do |sfx, pass|
      (pass == 1).then { @piano.play(:G4) }
      (pass == 10).then { sfx.play 0 }
    end

    [over, under, game_first].each do |program|
      interpreted, console = owners_on_both(program, frames: 20)
      assert_equal interpreted, console
    end
    assert_equal 1, console_run(under, frames: 20).sound_drops.dropped, "the console counts the note that did not play"
  end

  # A GROUP ON THE CONSOLE: the square voice the cry plays and the noise voice the hurt plays are
  # set the same way the interpreter sets them.
  GROUP_TONES = { "sfx.0": :half, "sfx.1": nil }.freeze

  def assert_backends_share_both_voices(program)
    assert_backends_share_the_voice(program, GROUP_TONES)
    assert_backends_share_the_voice(program, GROUP_TONES, channel: 4)
  end

  def test_the_console_cuts_an_effect_off_for_a_higher_one_of_its_group
    program = cry_then_hurt(cry_priority: 64, hurt_priority: 72)

    assert_equal [[0, setting(:half, 12)], [5, 0]], interpreted_changes(program, 1, GROUP_TONES, frames: 60),
                 "the cry is cut off five frames in"
    assert_backends_share_both_voices(program)
  end

  def test_the_console_does_not_play_a_lower_one_of_a_group
    assert_backends_share_both_voices(cry_then_hurt(cry_priority: 72, hurt_priority: 64))
  end

  def test_the_console_cuts_an_effect_off_on_a_tie_in_its_group
    assert_backends_share_both_voices(cry_then_hurt(cry_priority: 64, hurt_priority: 64))
  end

  def test_the_console_plays_effects_of_two_groups_together
    two_groups = game([cry(72, group: :voice), hurt(64, group: :sword)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 1 }
    end

    assert_backends_share_both_voices(two_groups)
  end

  # Asked for again, it goes quiet until its first note — which, in this one, comes five frames in.
  def test_the_console_stops_an_effect_of_a_group_asked_for_again
    late = Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 5, key: :C5, length: 40)])])
    program = game([late]) { |sfx, pass| ((pass == 3) | (pass == 20)).then { sfx.play 0 } }

    assert_equal [[0, setting(:half, 12)], [12, 0], [17, setting(:half, 12)], [57, 0]],
                 interpreted_changes(program, 1, GROUP_TONES, frames: 80)
    assert_backends_share_the_voice(program, GROUP_TONES)
  end

  # Two of a group asked for on one pass, in either order; and one asked for again on the pass a
  # lower one is, sounding or not.
  def test_the_console_decides_several_asks_on_one_pass_the_way_the_interpreter_does
    together = [[1, 0], [0, 1]].map do |order|
      game([cry(64), hurt(72)]) { |sfx, pass| (pass == 3).then { order.each { |which| sfx.play which } } }
    end
    again_and_lower = game([cry(72), hurt(64)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 0; sfx.play 1 }
    end
    twice_and_lower = game([cry(72), hurt(64)]) { |sfx, pass| (pass == 3).then { sfx.play 0; sfx.play 0; sfx.play 1 } }

    [*together, again_and_lower, twice_and_lower].each { |program| assert_backends_share_both_voices(program) }
  end

  # A number the game works out, naming an effect with no group in a list that has groups in it,
  # plays it alongside the one sounding.
  def test_the_console_plays_an_effect_with_no_group_from_a_list_with_groups
    program = game([cry(72), hurt(64, group: nil)]) do |sfx, pass|
      which = var :which, 0
      (pass == 3).then { sfx.play which }
      (pass == 4).then { which.set 1 }
      (pass == 8).then { sfx.play which }
    end

    assert_includes notes_by_frame(program, 20)[9], [:"sfx.1", NOTES[:C3]]
    assert_backends_share_both_voices(program)
  end

  # RECORDED EFFECTS IN A GROUP: cut off, not played for a lower one, on a tie, and asked for
  # again — whose each mixer voice is, the same on both backends.
  def long_recorded(key, priority)
    Score.new(tempo: 150, priority: priority, group: :voice,
              parts: [Part.new(plays: :piano, notes: [Note.new(at: 5, key: key, length: 60)])])
  end

  def recorded_pair(first:, second:, asks: [0, 1])
    game([long_recorded(:C4, first), long_recorded(:E4, second)]) do |sfx, pass|
      (pass == 3).then { sfx.play asks.first }
      (pass == 14).then { sfx.play asks.last }
    end
  end

  def test_the_console_decides_a_group_of_recorded_effects_the_way_the_interpreter_does
    cry_alone = [[:"sfx.0", 0]]
    hurt_alone = [[:"sfx.1", 0]]
    {
      recorded_pair(first: 64, second: 72) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 72, second: 64) => { 10 => cry_alone, 22 => cry_alone },
      recorded_pair(first: 64, second: 64) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 64, second: 72, asks: [0, 0]) => { 10 => cry_alone, 17 => [], 22 => cry_alone },
    }.each do |program, moments|
      moments.each do |frames, owners|
        interpreted, console = owners_on_both(program, frames: frames)
        assert_equal owners, interpreted, "#{frames} frames in"
        assert_equal interpreted, console, "#{frames} frames in"
      end
    end
  end

  # A fading note taken first, a song part that lost its voice having one again at its next note,
  # and a silent note taking none, on both backends.
  def test_the_console_takes_fading_notes_gives_voices_back_and_passes_over_silent_notes
    fading = game([recorded_hit(68)], tune: chord(16, length: 8, envelope: { release: 1.0 })) do |sfx, pass|
      (pass == 12).then { sfx.play 0 }
    end
    again = game([recorded_hit(68)], tune: chord(16, at: [0, 60])) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    quiet = Score.new(tempo: 150, priority: 68, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :D5, volume: 0),
    ])])
    silent = game([quiet], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    [[fading, 18], [again, 30], [again, 72], [silent, 15], [silent, 27]].each do |program, frames|
      interpreted, console = owners_on_both(program, frames: frames)
      assert_equal interpreted, console, "#{frames} frames in"
    end
  end

  # An effect filling every voice: the song's note under it is not played, and its next one is.
  def test_the_console_plays_the_songs_next_note_once_an_effect_filling_the_mixer_ends
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    program = game([recorded_hit(68, parts: 16)], tune: tune) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    [25, 45].each do |frames|
      interpreted, console = owners_on_both(program, frames: frames)
      assert_equal interpreted, console, "#{frames} frames in"
    end
    assert_equal [[:song, 0]], Reference.new.run(program, frames: 45).sound_owners
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end.
  def test_the_console_keeps_and_lets_go_of_an_effects_voice_the_way_the_interpreter_does
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
      .zip([12, 18, 40, 26]).each do |(program, owners), frames|
        interpreted, console = owners_on_both(program, frames: frames)
        assert_equal owners, interpreted, "#{frames} frames in"
        assert_equal interpreted, console, "#{frames} frames in"
      end
  end

  # An effect's voice plays at the effect's own volume while the music volume moves, and reads its
  # recording at its note's pitch.
  def test_the_console_plays_an_effects_recording_at_its_own_volume_and_pitch
    high = Score.new(tempo: 150, length: 200, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C5)])])
    program = game([high], tune: chord(1)) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 6).then { music_volume 50 }
    end
    voices = console_voices(program, frames: 12).to_h { |voice| [voice.owner, voice] }
    written = RubyGBA::IR::Tunes.mix_loudness(12) # a part's volume when it says none

    assert_equal written, voices.fetch([:"sfx.0", 0]).volume
    assert_equal RubyGBA::IR::Tunes.scaled_volume(written, 8), voices.fetch([:song, 0]).volume, "half the music volume"
    assert_in_delta 2.0, voices.fetch([:"sfx.0", 0]).step.fdiv(voices.fetch([:song, 0]).step), 0.01,
                    "read twice as fast, an octave above the song's C4"
  end

  # --- what it costs ---

  # THE PROFILE COUNTS IT, inside the routine that answers the display, which is where the player
  # runs: a game whose effects are sounding spends more there than the same game with them silent.
  def test_the_profile_counts_what_the_sound_effects_cost
    interrupt_samples = lambda do |playing|
      effects = Array.new(8) { |n| every_ten_ticks(:C5, :E5, :G5, priority: n) }
      rom = RubyGBA.build("SFXCOST", code: "ZSFX", maker: "01", out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        enable_sound
        sfx = sound_effects :sfx, effects
        game_loop { effects.size.times { |n| sfx.play n } if playing }
      end
      RubyGBA::Profiler.run(rom, frames: 30, picture: false).lines.find { |line| line.name == :__interrupt }.samples
    end

    assert_operator interrupt_samples.call(true), :>, interrupt_samples.call(false)
  end

  # --- what cannot be had, said plainly ---

  def build_error(&program)
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
        instance_exec(&program)
      end
    end
    err.message
  end

  def test_an_effect_that_loops_is_a_friendly_error
    looping = [Score.new(tempo: 150, loop_from: 5, parts: [Part.new(notes: [Note.new(at: 0, key: :C5, length: 10)])])]

    assert_match(/loop_from:/, build_error { sound_effects :sfx, looping })
  end

  # What the finished program's checks say about a game whose one effect is +score+.
  def findings_for(score)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { rumble: score }
      game_loop { sfx.play :rumble }
    end
    b.emit_pending_functions
    RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false).findings
  end

  # An effect with more parts than it has voices names the effect, and offers the voices with
  # room — the wave voice among them.
  def test_an_effect_with_more_parts_than_it_has_voices_is_a_friendly_error
    notes = [Note.new(at: 0, key: :C5)]
    three = Score.new(parts: [Part.new(notes: notes), Part.new(notes: notes), Part.new(notes: notes)])
    found = findings_for(three).find { |finding| finding.check == :song_too_many_parts }

    assert found.error?
    assert_match(/The sound effect :rumble of :sfx has 3 parts/, found.message)
    assert_match(/A sound effect can have 2 of them at most/, found.message)
    assert_match(/One part can play an instrument/, found.message)
    assert_match(/plays: :wave/, found.message)
  end

  # A warning about a note in an effect names the effect, and offers the voices that go lower.
  def test_a_warning_about_an_effects_note_names_the_effect
    low = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: 30)])])
    found = findings_for(low).find { |finding| finding.check == :square_note_too_low }

    assert_match(/the sound effect :rumble of :sfx/, found.message)
    assert_match(/plays: :wave/, found.message)
  end

  def test_a_group_that_is_not_a_name_is_a_friendly_error
    named_by_text = [cry(64, group: "voice")]

    assert_match(/A group is a name/, build_error { sound_effects :sfx, named_by_text })
  end

  # A song plays one at a time already, so a group on one is a mistake worth saying.
  def test_a_song_in_a_group_is_a_friendly_error
    grouped = { theme: cry(0) }
    message = build_error { songs :music, grouped }

    assert_match(/:theme of :music/, message)
    assert_match(/group:/, message)
  end

  def test_a_priority_that_is_not_a_byte_is_a_friendly_error
    loud = [every_ten_ticks(:C5, priority: 300)]

    assert_match(/0 to 255/, build_error { sound_effects :sfx, loud })
  end

  def test_a_name_or_number_the_effects_do_not_have_is_a_friendly_error
    effects = { hit: every_ten_ticks(:C5) }

    assert_match(/:spark/, build_error { sound_effects(:sfx, effects).play :spark })
    assert_match(/0 to 0/, build_error { sound_effects(:sfx, effects).play 3 })
  end
end
