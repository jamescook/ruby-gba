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

end
