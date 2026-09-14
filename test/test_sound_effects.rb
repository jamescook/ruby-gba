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

  # A game with +effects+ as sound effects and, when given, +tune+ as the one song it plays from
  # its first pass. The block runs each pass with the effects and the pass number.
  def game(effects, tune: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [tune] if tune
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add 1
        music&.play 0
        instance_exec(sfx, pass, &body)
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
  # 11 to its end on frame 40. Both play the first square voice, or both whatever +plays+ names.
  # The effect's part is quieter, and a thinner tone, so the console can tell the two apart.
  def song_and_effect(song_priority:, effect_priority:, plays: nil)
    tune = Score.new(tempo: 150, priority: song_priority, parts: [Part.new(plays: plays, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    hit = Score.new(tempo: 150, priority: effect_priority, parts: [Part.new(plays: plays, volume: 9, duty: :quarter, notes: [
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
    asked = lambda do |low_priority|
      program = game([every_ten_ticks(:C5, priority: low_priority), every_ten_ticks(:E5, priority: 50)]) do |sfx, pass|
        (pass == 3).then do
          sfx.play 1
          sfx.play 0
        end
      end
      notes_by_frame(program, 10)[4]
    end

    assert_equal [[:"sfx.1", NOTES[:E5]]], asked.call(10)
    assert_equal [[:"sfx.0", NOTES[:C5]]], asked.call(90)
    assert_equal [[:"sfx.0", NOTES[:C5]]], asked.call(50), "a tie goes to the effect declared first"
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
    rom = assemble_rom(program, name: "SFXVOICE")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sfx.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      settings = Array.new(frames) do
        probe.step(1)
        probe.read32(register) & SETTING
      end
      probe.close
      changes(settings)
    end
  end

  # The same, from what the interpreter says sounded on the voice: each note's setting, by who
  # played it, or 0 for a voice going quiet. The two start counting at different moments, so
  # both count from the first sound.
  def interpreted_changes(program, settings, frames:)
    heard = notes_by_frame(program, frames)
    current = 0
    changes((1..frames).map do |frame|
      who, frequency = heard[frame]&.last
      current = frequency.zero? ? 0 : settings.fetch(who) if who
      current
    end)
  end

  def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  # The two backends agree about when a voice changed and who it changed to, from the first sound
  # the interpreter heard to its last — the console runs on a little, since it starts later.
  def assert_backends_share_the_voice(program, settings, register: SQUARE_1)
    want = interpreted_changes(program, settings, frames: 60)
    got = console_changes(program, register, frames: 75).take_while { |frame, _| frame <= 58 - 2 }

    assert_equal want.take_while { |frame, _| frame <= 56 }, got
  end

  def self.square_setting(duty, volume) = (RubyGBA::Sound::Registers.duty_bits(duty) << 6) | (volume << 12)
  def square_setting(duty, volume) = self.class.square_setting(duty, volume)

  SONG_SETTING = { "music.0": square_setting(:half, 12), "sfx.0": square_setting(:quarter, 9) }.freeze

  # THE TWO BACKENDS AGREE ABOUT WHO SOUNDED ON A SHARED VOICE, and when, one way round and the
  # other: the effect taking the first square voice and the song coming back after it, and the
  # song keeping it against an effect it outranks.
  def test_the_console_shares_a_square_voice_the_way_the_interpreter_does
    taken = song_and_effect(song_priority: 0, effect_priority: 68)

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [38, 0], [40, SONG_SETTING[:"music.0"]]],
                 interpreted_changes(taken, SONG_SETTING, frames: 60)
    assert_backends_share_the_voice(taken, SONG_SETTING)
    assert_backends_share_the_voice(song_and_effect(song_priority: 80, effect_priority: 68), SONG_SETTING)
  end

  def test_the_console_shares_the_noise_voice_the_way_the_interpreter_does
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :noise)
    settings = { "music.0": 12 << 12, "sfx.0": 9 << 12 }

    assert_equal [12 << 12, 9 << 12, 0, 12 << 12], interpreted_changes(program, settings, frames: 60).map(&:last),
                 "the effect takes the voice, is silenced at its end, and the song comes back"
    assert_backends_share_the_voice(program, settings, register: NOISE)
  end

  # With no song at all, and asked for twice so it starts again.
  def test_the_console_plays_an_effect_once_and_starts_it_again
    program = game([every_ten_ticks(:C5, :E5)]) { |sfx, pass| ((pass == 3) | (pass == 8)).then { sfx.play 0 } }
    settings = { "sfx.0": square_setting(:half, 12) }

    assert_equal [[0, settings[:"sfx.0"]], [39, 0]], interpreted_changes(program, settings, frames: 60)
    assert_backends_share_the_voice(program, settings)
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
    settings = { "sfx.0": square_setting(:half, 9), "sfx.1": square_setting(:half, 5) }

    assert_equal [[0, settings[:"sfx.1"]], [24, 0]], interpreted_changes(program, settings, frames: 60)
    assert_backends_share_the_voice(program, settings)
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
    settings = { "sfx.0": square_setting(:half, 5), "sfx.1": square_setting(:half, 9) }

    assert_equal [[0, settings[:"sfx.0"]], [24, 0], [30, settings[:"sfx.1"]], [54, 0]],
                 interpreted_changes(program, settings, frames: 60)
    assert_backends_share_the_voice(program, settings)
  end

  # A song holding one long note, and an effect over it from pass 10; the block says what else
  # the game does on each pass.
  def long_note_under_an_effect(&body)
    tune = Score.new(tempo: 150, length: 200, parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(volume: 9, duty: :quarter, notes: [
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
                 interpreted_changes(program, SONG_SETTING, frames: 60)
    assert_backends_share_the_voice(program, SONG_SETTING)
  end

  # ...and a music volume moving while an effect sounds does not start the song's lost note again
  # over it, then or after the effect ends.
  def test_the_console_keeps_an_effects_voice_when_the_music_volume_moves
    program = long_note_under_an_effect { |pass| (pass == 20).then { music_volume 50 } }

    assert_equal [[0, SONG_SETTING[:"music.0"]], [9, SONG_SETTING[:"sfx.0"]], [43, 0]],
                 interpreted_changes(program, SONG_SETTING, frames: 60)
    assert_backends_share_the_voice(program, SONG_SETTING)
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

  def test_an_effect_that_plays_a_recording_is_a_friendly_error
    piano = { hit: every_ten_ticks(:C5, plays: :piano) }
    message = build_error { sound_effects :sfx, piano }

    assert_match(/:hit of :sfx/, message)
    assert_match(/`plays: :noise`/, message)
  end

  def test_an_effect_on_the_wave_voice_is_a_friendly_error
    pad = [every_ten_ticks(:C5, plays: :triangle)]

    assert_match(/wave voice/, build_error { sound_effects :sfx, pad })
  end

  def test_an_effect_that_loops_is_a_friendly_error
    looping = [Score.new(tempo: 150, loop_from: 5, parts: [Part.new(notes: [Note.new(at: 0, key: :C5, length: 10)])])]

    assert_match(/loop_from:/, build_error { sound_effects :sfx, looping })
  end

  def test_an_effect_with_more_parts_than_it_has_voices_is_a_friendly_error
    notes = [Note.new(at: 0, key: :C5)]
    three = [Score.new(parts: [Part.new(notes: notes), Part.new(notes: notes), Part.new(notes: notes)])]
    message = build_error { sound_effects :sfx, three }

    assert_match(/0 of :sfx/, message)
    assert_match(/2/, message)
  end

  # A warning about a note in an effect names the effect, and offers only what an effect can do.
  def test_a_warning_about_an_effects_note_names_the_effect
    low = [Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: 30)])])]
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { rumble: low.first }
      game_loop { sfx.play :rumble }
    end
    b.emit_pending_functions
    found = RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false).warnings
                                              .find { |finding| finding.check == :square_note_too_low }

    assert_match(/the sound effect :rumble of :sfx/, found.message)
    refute_match(/plays: :wave/, found.message)
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
