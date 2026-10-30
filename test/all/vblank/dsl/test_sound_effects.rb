# frozen_string_literal: true

require "test_helper"

# The games these tests play and what the run's player says about them, kept once for the same
# games on the Advance's cartridge (test/lowering/gba/vblank/dsl/test_sound_effects_cartridge.rb).
module SoundEffectsGames
  include SharedConstants

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # A voice's setting that reads back: a square voice's tone, and the volume — or for a +tone+ of
  # :wave, the nearest of the wave voice's five volumes.
  def self.setting(tone, volume)
    return VBlank::Audio::Sound::Registers::WAVE_VOLUMES.fetch(VBlank::Audio::Sound.wave_level(volume)) if tone == :wave

    ((tone ? VBlank::Audio::Sound::Registers.duty_bits(tone) : 0) << 6) | (volume << 12)
  end

  # Who plays each voice in what tone, by who, for #interpreted_changes.
  SONG_TONES = Ractor.make_shareable({ "music.0": :half, "sfx.0": :quarter })
  SONG_SETTING = Ractor.make_shareable({ "music.0": setting(:half, 12), "sfx.0": setting(:quarter, 9) })
  NOISE_TONES = Ractor.make_shareable({ "music.0": nil, "sfx.0": nil })
  WAVE_TONES = Ractor.make_shareable({ "music.0": :wave, "sfx.0": :wave })
  BOTH_SIDES_TONES = Ractor.make_shareable({ "music.0": :half, "sfx.0": :quarter,
                                             "sfx.1": { 1 => :eighth, 2 => :three_quarter } })
  PICKED_TONES = Ractor.make_shareable({ "sfx.0": :half, "sfx.1": :half })
  # A GROUP: the square voice the cry plays and the noise voice the hurt plays.
  GROUP_TONES = Ractor.make_shareable({ "sfx.0": :half, "sfx.1": nil })

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame.
  private def every_ten_ticks(*keys, plays: nil, priority: 0, length: nil)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key, length: length) }
    Score.new(tempo: 150, priority: priority, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game with +effects+ as sound effects and, when given, +tune+ as the song it plays from its
  # first pass — or a list of them, the first played. The block runs each pass with the effects,
  # the pass number and the songs. (Effects that play a recording are tested on the Advance alone,
  # in test_sound_effects_on_the_advance.rb.)
  private def game(effects, tune: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
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

  # The song's one part sounds on frames 2, 22 and 42; the effect, on the same voice, from frame
  # 11 to its end on frame 40. Both play the first square voice, or both whatever +plays+ names —
  # the effect +effect_plays+, when that is given. The effect's part is quieter, and a thinner
  # tone, so the console can tell the two apart.
  private def song_and_effect(song_priority:, effect_priority:, plays: nil, effect_plays: plays)
    tune = Score.new(tempo: 150, priority: song_priority, parts: [Part.new(plays: plays, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: effect_priority, parts: [Part.new(plays: effect_plays, volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5),
    ])])
    game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
  end

  # A song on the first square voice, and an effect over it whose second note is at volume 0.
  private def silent_note_over_a_song
    tune = Score.new(tempo: 150, parts: [Part.new(notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5, volume: 0),
    ])])
    game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
  end

  # A song on the triangle, and an effect over it on the sawtooth whose second note is at volume 1.
  private def too_quiet_for_the_wave_voice
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :triangle, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: :sawtooth, volume: 9, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5, volume: 1),
    ])])
    game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
  end

  # A song whose part, on the voice +plays+ names, swells in from volume 0 on every note, outranking
  # an effect asked for on that voice on pass 10.
  private def swelling_song_and_effect(plays: nil)
    tune = Score.new(tempo: 150, priority: 80, parts: [Part.new(plays: plays, volume: 0, swell: 3, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: plays, volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5),
    ])])
    game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
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

  # A CRY on the first square voice, three notes ten ticks apart, and a HURT on the noise voice
  # — different voices, so without a group the two would sound together.
  private def cry(priority, group: :voice)
    Score.new(tempo: 150, priority: priority, group: group,
              parts: [Part.new(notes: %i[C5 E5 G5].each_with_index.map { |key, n| Note.new(at: n * 10, key: key) })])
  end

  private def hurt(priority, group: :voice)
    Score.new(tempo: 150, priority: priority, group: group,
              parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: :C3, length: 30)])])
  end

  # The cry asked for on pass 3, and the hurt on pass 8.
  private def cry_then_hurt(cry_priority:, hurt_priority:, group: :voice)
    game([cry(cry_priority, group: group), hurt(hurt_priority, group: group)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 1 }
    end
  end

  # The same, from what the interpreter logs each voice was set to: a note's volume and the tone of
  # the part that played it (+tones+, by who; none on the noise voice), or 0 for a voice going
  # quiet. The two start counting at different moments, so both count from the first sound.
  private def interpreted_changes(program, channel, tones, frames:)
    i = game_player
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

  # [frames since the first setting that was not 0, setting] for each change in +settings+, one
  # setting a frame.
  private def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  private def setting(tone, volume) = SoundEffectsGames.setting(tone, volume)

  # THE WAVEFORM IN WAVE RAM. A tune on the triangle with a note every ten frames; an effect on the
  # sawtooth from pass 10, twelve frames long; and from pass 16 a second tune, on the sine, which
  # starts while the effect holds the voice. Its first note is lost to the effect, and its second
  # is heard in the sine.
  #
  # The effect opens with a rest, which loads nothing, and a note too quiet to hear, which loads
  # the sawtooth all the same — a note, heard or not, is in its own waveform.
  private def two_tunes_on_the_wave_voice_under_an_effect
    triangle = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :triangle)
    sine = every_ten_ticks(:C4, :E4, :G4, :C5, :E5, plays: :sine)
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: :sawtooth, volume: 9, notes: [
      Note.new(at: 0, key: nil), Note.new(at: 2, key: :C5, volume: 1), Note.new(at: 4, key: :C5, length: 8),
    ])])
    game([hit], tune: [triangle, sine]) do |sfx, pass, music|
      (pass == 10).then { sfx.play 0 }
      (pass >= 16).then { music.play 1 }
    end
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

  # A SONG RANKED BETWEEN TWO EFFECTS, so the player walks the effects above it before the song's
  # parts and the one below it after them. The higher one takes the first square voice from the
  # song; the lower one, asked for while that is sounding, is silent there and heard on the second
  # square voice, which nobody else wants.
  private def effects_on_both_sides_of_the_songs_rank
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
    game([high, low], tune: tune) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      (pass == 20).then { sfx.play 1 }
    end
  end

  # One effect with no song at all, asked for on pass 3 and again on pass 8.
  private def effect_asked_for_twice
    game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }
  end

  # The quieter of two effects picked by a number, and then a number naming no effect.
  private def effect_picked_by_a_number
    quiet = Score.new(tempo: 150, parts: [Part.new(volume: 5, notes: [Note.new(at: 0, key: :C5)])])
    loud = Score.new(tempo: 150, priority: 90, parts: [Part.new(volume: 9, notes: [Note.new(at: 0, key: :C5)])])
    game([loud, quiet]) do |sfx, pass|
      which = var :which, 1
      (pass == 3).then { sfx.play which }
      (pass == 40).then { which.set! 2 }
      (pass == 41).then { sfx.play which }
    end
  end

  # Two effects on one voice, of one priority, asked for on one frame, the second first.
  private def two_effects_tied_on_one_voice
    first = Score.new(tempo: 150, parts: [Part.new(volume: 5, notes: [Note.new(at: 0, key: :C5)])])
    second = Score.new(tempo: 150, parts: [Part.new(volume: 9, notes: [Note.new(at: 0, key: :C5), Note.new(at: 30, key: :E5)])])
    game([first, second]) do |sfx, pass|
      (pass == 3).then do
        sfx.play 1
        sfx.play 0
      end
    end
  end

  # A song holding one long note, and an effect over it from pass 10, on the voice +plays+ and
  # +effect_plays+ name; the block says what else the game does on each pass.
  private def long_note_under_an_effect(plays: nil, effect_plays: nil, &body)
    tune = Score.new(tempo: 150, length: 200, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C4)])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: effect_plays, volume: 9, duty: :quarter, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :E5),
    ])])
    game([hit], tune: tune) do |sfx, pass|
      (pass == 10).then { sfx.play 0 }
      instance_exec(pass, &body)
    end
  end

  # An effect of a group whose one note comes five frames in, asked for on pass 3 and again on 20.
  private def late_effect_of_a_group_asked_for_twice
    late = Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 5, key: :C5, length: 40)])])
    game([late]) { |sfx, pass| ((pass == 3) | (pass == 20)).then { sfx.play 0 } }
  end

  # The cry, and then by a number the game works out a hurt with no group, in one list.
  private def ungrouped_effect_from_a_list_with_groups
    game([cry(72), hurt(64, group: nil)]) do |sfx, pass|
      which = var :which, 0
      (pass == 3).then { sfx.play which }
      (pass == 4).then { which.set! 1 }
      (pass == 8).then { sfx.play which }
    end
  end
end

# A SCORE PLAYED ONCE, AS A SOUND EFFECT, OVER THE SONG THAT IS PLAYING.
#
# A sword hit, a door, a chest opening: each is a short run of notes decoded from somewhere the
# same way a tune is, and each plays over the room's music without stopping it. When the effect
# and the song want the same voice, the one with the higher priority sounds on it.
class TestSoundEffects < Minitest::Test
  include SoundEffectsGames

  # --- one effect on its own ---

  # Asked for on pass 3, it starts on the frame after, the way a song does, plays each note once
  # and goes quiet at its end rather than coming round again.
  def test_an_effect_plays_once_from_the_frame_it_is_asked_for
    program = game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| (pass == 3).then { sfx.play 0 } }

    assert_equal({ 4 => [[:"sfx.0", NOTES[:C5]]], 14 => [[:"sfx.0", NOTES[:E5]]], 38 => [[:"sfx.0", 0]] },
                 notes_by_frame(program, 80))
  end

  # --- over the song, on the same voice ---

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

  # ...and the other way round: an effect that outranks the song starts on the frame the song's
  # next note is due, and the song's note is never written, since the effect wrote the voice first.
  def test_a_song_note_that_loses_its_voice_on_the_frame_it_starts_is_never_played
    program = game([every_ten_ticks(:C5, priority: 68)], tune: every_ten_ticks(:C4, :E4, :G4)) do |sfx, pass|
      (pass == 21).then { sfx.play 0 }
    end

    assert_equal [[:"sfx.0", NOTES[:C5]]], notes_by_frame(program, 30)[22]
  end

  # A note at volume 0 sounds nothing, so it lets the voice go the way a rest does: the song's note
  # on frame 22 is heard. (The console playing it is in the cartridge's tests.)
  def test_a_silent_note_lets_the_voice_go
    assert_equal [[:"music.0", NOTES[:E4]]], notes_by_frame(silent_note_over_a_song, 30)[22]
  end

  # A NOTE THAT SWELLS IN FROM VOLUME 0 is sounding from its first step, so a song that outranks an
  # effect keeps its voice through one, as through any note it plays — a drum's as a square's.
  def test_a_note_swelling_from_nothing_keeps_its_voice
    [nil, :noise].each do |plays|
      assert_equal({ 2 => [[:"music.0", NOTES[:C4]]], 22 => [[:"music.0", NOTES[:E4]]],
                     42 => [[:"music.0", NOTES[:G4]]] }, notes_by_frame(swelling_song_and_effect(plays: plays), 50),
                   "on #{plays || :square}")
    end
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

  # The wave voice has five volumes, and the nearest to 1 of 15 is none: that note is silent, so it
  # lets the voice go, and the song's note on frame 22 is heard.
  def test_a_note_too_quiet_for_the_wave_voice_lets_it_go
    assert_equal [[:"music.0", NOTES[:E4]]], notes_by_frame(too_quiet_for_the_wave_voice, 30)[22]
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

  # --- one at a time, in a group ---

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
    i = game_player.run(cry_then_hurt(cry_priority: 72, hurt_priority: 64), frames: 40)

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
      i = game_player.run(program, frames: 20)
      refute_includes i.audio, [:sound_effect, :"sfx.1"]
    end
  end

  # Two of a group asked for on one pass: the higher priority starts, whichever was asked first.
  def test_of_two_asked_for_together_in_a_group_the_higher_priority_starts
    [[1, 0], [0, 1]].each do |order|
      program = game([cry(64), hurt(72)]) { |sfx, pass| (pass == 3).then { order.each { |which| sfx.play which } } }
      i = game_player.run(program, frames: 10)

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
      (pass == 4).then { which.set! 7 }
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
    i = game_player
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
    i = game_player.run(program, frames: 20)
    after = i.audio.drop_while { |entry| entry != [:sound_effect, :"sfx.0"] }

    assert_empty after.select { |entry| entry[0] == :loudness }, "nothing set the effect's voice to a music volume"
  end

  # --- how each voice was set, frame by frame ---
  #
  # What the run's player logs each voice was set to. The console setting its own voices the same
  # way, register by register, is in
  # test/lowering/gba/vblank/dsl/test_sound_effects_cartridge.rb, which holds each of these games
  # to the same answers on the Advance's cartridge.

  # THE EFFECT TAKES THE FIRST SQUARE VOICE and the song comes back after it.
  def test_an_effect_takes_a_square_voice_and_the_song_comes_back_after_it
    taken = song_and_effect(song_priority: 0, effect_priority: 68)

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [38, 0], [40, SONG_SETTING[:"music.0"]]],
                 interpreted_changes(taken, 1, SONG_TONES, frames: 60)
  end

  def test_an_effect_takes_the_noise_voice_and_the_song_comes_back_after_it
    assert_equal [12 << 12, 9 << 12, 0, 12 << 12],
                 interpreted_changes(song_and_effect(song_priority: 0, effect_priority: 68, plays: :noise),
                                     4, NOISE_TONES, frames: 60).map(&:last),
                 "the effect takes the voice, is silenced at its end, and the song comes back"
  end

  def test_an_effect_takes_the_wave_voice_and_the_song_comes_back_after_it
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :triangle, effect_plays: :sawtooth)

    assert_equal [setting(:wave, 12), setting(:wave, 9), 0, setting(:wave, 12)],
                 interpreted_changes(program, 3, WAVE_TONES, frames: 60).map(&:last),
                 "the effect takes the voice, is silenced at its end, and the song comes back"
  end

  # THE WAVEFORM. The wave voice loops whatever waveform is in wave RAM, and there is room there
  # for one, so an effect's note has to put its own there — and the song's note after it has to
  # put the song's back. (See #two_tunes_on_the_wave_voice_under_an_effect for the game.)
  def test_each_note_on_the_wave_voice_loads_its_own_waveform
    assert_equal [[0, waveform(:triangle)], [11, waveform(:sawtooth)], [25, waveform(:sine)]],
                 interpreted_waveforms(two_tunes_on_the_wave_voice_under_an_effect, frames: 40)
  end

  # A SONG RANKED BETWEEN TWO EFFECTS: the lower one, asked for while the higher one is sounding,
  # is silent on the first square voice and heard on the second, which nobody else wants.
  def test_an_effect_below_the_song_is_heard_on_a_voice_nobody_else_wants
    assert_equal [[0, setting(:three_quarter, 7)], [24, 0]],
                 interpreted_changes(effects_on_both_sides_of_the_songs_rank, 2, BOTH_SIDES_TONES, frames: 60)
  end

  # With no song at all, and asked for twice so it starts again.
  def test_an_effect_asked_for_twice_holds_its_voice_until_its_second_run_ends
    assert_equal [[0, setting(:half, 12)], [39, 0]],
                 interpreted_changes(effect_asked_for_twice, 1, { "sfx.0": :half }, frames: 60)
  end

  # By a number the game works out, turned into its place in the table: the quieter of the two,
  # and then nothing for a number naming no effect.
  def test_the_number_the_game_works_out_sets_the_voice_for_its_effect
    assert_equal [[0, setting(:half, 5)], [24, 0]],
                 interpreted_changes(effect_picked_by_a_number, 1, PICKED_TONES, frames: 60)
  end

  # Two effects on one voice, of one priority, asked for on one frame: the one declared first.
  def test_a_tie_between_effects_sets_the_voice_for_the_one_declared_first
    assert_equal [[0, setting(:half, 5)], [24, 0], [30, setting(:half, 9)], [54, 0]],
                 interpreted_changes(two_effects_tied_on_one_voice, 1, PICKED_TONES, frames: 60)
  end

  # The song starting over while an effect sounds leaves the effect's voice alone.
  def test_the_song_starting_over_leaves_the_effects_voice_setting_alone
    program = long_note_under_an_effect { |pass| (pass == 15).then { stop_music } }

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [43, 0]],
                 interpreted_changes(program, 1, SONG_TONES, frames: 60)
  end

  # ...and a music volume moving while an effect sounds does not start the song's lost note again
  # over it, then or after the effect ends.
  def test_the_music_volume_moving_leaves_the_effects_voice_setting_alone
    program = long_note_under_an_effect { |pass| (pass == 20).then { music_volume 50 } }

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [43, 0]],
                 interpreted_changes(program, 1, SONG_TONES, frames: 60)
  end

  # ...and the same on the wave voice, whose held note takes a new volume without starting again.
  def test_the_music_volume_moving_leaves_the_effects_wave_voice_setting_alone
    program = long_note_under_an_effect(plays: :triangle, effect_plays: :sawtooth) do |pass|
      (pass == 20).then { music_volume 50 }
    end

    assert_equal [[0, setting(:wave, 12)], [9, setting(:wave, 9)], [43, 0]],
                 interpreted_changes(program, 3, WAVE_TONES, frames: 60)
  end

  # A GROUP: the cry is cut off five frames in by the hurt, which outranks it.
  def test_an_effect_cut_off_by_a_higher_one_of_its_group_lets_its_voice_go
    assert_equal [[0, setting(:half, 12)], [5, 0]],
                 interpreted_changes(cry_then_hurt(cry_priority: 64, hurt_priority: 72), 1, GROUP_TONES, frames: 60),
                 "the cry is cut off five frames in"
  end

  # Asked for again, it goes quiet until its first note — which, in this one, comes five frames in.
  def test_an_effect_of_a_group_asked_for_again_is_quiet_until_its_first_note
    assert_equal [[0, setting(:half, 12)], [12, 0], [17, setting(:half, 12)], [57, 0]],
                 interpreted_changes(late_effect_of_a_group_asked_for_twice, 1, GROUP_TONES, frames: 80)
  end

  # A number the game works out, naming an effect with no group in a list that has groups in it,
  # plays it alongside the one sounding.
  def test_an_effect_with_no_group_from_a_list_with_groups_plays_alongside
    assert_includes notes_by_frame(ungrouped_effect_from_a_list_with_groups, 20)[9], [:"sfx.1", NOTES[:C3]]
  end

  # What the sound effects cost, as the profile counts it on the Advance's cartridge, is in the
  # cartridge's tests too.

  # --- what cannot be had, said plainly ---

  private def build_error(&program)
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
  private def findings_for(score)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { rumble: score }
      game_loop { sfx.play :rumble }
    end
    b.finalize_program
    VBlank::IR::Guardrails::Validator.new.run(b.program, autofix: false).findings
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
