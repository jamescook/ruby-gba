# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/dsl/test_sound_effects.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A SCORE PLAYED ONCE, AS A SOUND EFFECT, OVER THE SONG THAT IS PLAYING.
#
# A sword hit, a door, a chest opening: each is a short run of notes decoded from somewhere the
# same way a tune is, and each plays over the room's music without stopping it. When the effect
# and the song want the same voice, the one with the higher priority sounds on it.
class TestSoundEffectsOnTheAdvance < Minitest::Test
  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES

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

  # --- one effect on its own ---

  # The same Score named as a tune comes round, as any tune does: played as an effect it is walked
  # once as written, and played as a tune it is put right for coming round.
  def test_an_effect_named_as_a_tune_comes_round
    program = game([every_ten_ticks(:C5, :E5, length: 5)]) { |_sfx, pass| (pass == 1).then { play_song :"sfx.0" } }
    starts = notes_by_frame(program, 80).values.flatten(1).count([:"sfx.0", NOTES[:C5]])

    assert_operator starts, :>=, 2, "the tune plays its first note again each time it comes round"
  end

  # --- over the song, on the same voice ---

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

  # --- on the wave voice ---

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

  # --- asked for again, and several at once ---

  # --- on the mixer ---

  # The voices sounding after +frames+, from the interpreter: whose each one is, and the recording
  # it plays.
  private def voices_after(program, frames)
    i = game_player.run(program, frames: frames)
    i.sound_owners.zip(i.active_samples)
  end

  # --- sharing the mixer ---

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

  SONG_PARTS = Array.new(16) { |part| [:song, part] }.freeze

  # --- one at a time, in a group ---

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

  # --- picked by name, or by a number the game works out ---

  # --- the song around an effect ---

  # --- the console ---

  # What a voice is set to that reads back: its volume, and a square voice's tone. Its pitch is
  # written with the bit that starts the note and does not read back, so the effect's part is
  # told from the song's by being quieter and thinner.
  SETTING = 0xF0C0

  SQUARE_1 = RubyGBA::Console::Hardware::REG_SOUND1CNT_H
  NOISE = RubyGBA::Console::Hardware::REG_SOUND4CNT_L

  # How a voice was set on the console: [frames since it first sounded, setting] for each change.
  private def console_changes(program, register, frames:)
    changes(console_readings(program, frames: frames) { |probe| probe.read32(register) & SETTING })
  end

  # What the block reads from the console after each of +frames+ frames.
  private def console_readings(program, frames:)
    rom = assemble_rom(program, name: "SFXVOICE")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sfx.gba")
      rom.write(path)
      probe = RubyGBA::Diagnostics::Emulator.probe(path)
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

  private def changes(settings)
    runs = settings.each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map(&:first)
    runs = runs.drop_while { |setting, _| setting.zero? }
    runs.map { |setting, frame| [frame - runs.first.last, setting] }
  end

  REGISTERS = { 1 => SQUARE_1, 2 => RubyGBA::Console::Hardware::REG_SOUND2CNT_L, 3 => RubyGBA::Console::Hardware::REG_SOUND3CNT_H,
                4 => NOISE }.freeze

  # The two backends agree about when a voice changed and what it changed to, from the first sound
  # the interpreter heard to its last — the console runs on a little, since it starts later.
  private def assert_backends_share_the_voice(program, tones, channel: 1)
    want = interpreted_changes(program, channel, tones, frames: 60)
    got = console_changes(program, REGISTERS.fetch(channel), frames: 75).take_while { |frame, _| frame <= 56 }

    assert_equal want.take_while { |frame, _| frame <= 56 }, got, "the voice numbered #{channel}"
  end

  # A voice's setting that reads back: a square voice's tone, and the volume — or for a +tone+ of
  # :wave, the nearest of the wave voice's five volumes.
  def self.setting(tone, volume)
    return RubyGBA::Audio::Sound::Registers::WAVE_VOLUMES.fetch(RubyGBA::Audio::Sound.wave_level(volume)) if tone == :wave

    ((tone ? RubyGBA::Audio::Sound::Registers.duty_bits(tone) : 0) << 6) | (volume << 12)
  end
  private def setting(tone, volume) = self.class.setting(tone, volume)
  private def square_setting(tone, volume) = setting(tone, volume)

  SONG_TONES = { "music.0": :half, "sfx.0": :quarter }.freeze
  SONG_SETTING = { "music.0": setting(:half, 12), "sfx.0": setting(:quarter, 9) }.freeze

  WAVE_TONES = { "music.0": :wave, "sfx.0": :wave }.freeze

  # A waveform as the number wave RAM holds for it, reading its four words in order.
  private def waveform(shape)
    RubyGBA::Audio::Sound::Registers.wavetable_halfwords(shape).each_slice(2).each_with_index.sum do |(low, high), word|
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

  # ...and from the console, reading wave RAM once a frame from the frame the voice first sounds.
  private def console_waveforms(program, frames:)
    readings = console_readings(program, frames: frames) do |probe|
      ram = (0...4).sum { |word| probe.read32(RubyGBA::Console::Hardware::REG_WAVE_RAM + (word * 4)) << (32 * word) }
      [probe.read32(REGISTERS.fetch(3)) & SETTING, ram]
    end
    changes(readings.drop_while { |setting, _| setting.zero? }.map(&:last))
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

  # --- the console's mixer ---

  # Whose each sounding voice is, +frames+ in, on each backend — the console run a little longer,
  # since it starts later. Every program here holds its voices steady for longer than that.
  private def owners_on_both(program, frames:)
    [game_player.run(program, frames: frames).sound_owners, console_voices(program, frames: frames).map(&:owner)]
  end

  private def console_voices(program, frames:) = console_run(program, frames: frames).voices

  private def console_run(program, frames:) = assert_emulator_loads_rom(assemble_rom(program, name: "SFXMIX"), frames: frames + 2)

  # A GROUP ON THE CONSOLE: the square voice the cry plays and the noise voice the hurt plays are
  # set the same way the interpreter sets them.
  GROUP_TONES = { "sfx.0": :half, "sfx.1": nil }.freeze

  private def assert_backends_share_both_voices(program)
    assert_backends_share_the_voice(program, GROUP_TONES)
    assert_backends_share_the_voice(program, GROUP_TONES, channel: 4)
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

  # --- what it costs ---

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
    RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false).findings
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
    assert_equal [[:song, 0]], game_player.run(program, frames: 45).sound_owners
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
end
