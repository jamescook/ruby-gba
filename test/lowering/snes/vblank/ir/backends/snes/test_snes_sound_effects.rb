# frozen_string_literal: true

require "test_helper"

# SOUND EFFECTS ON A SUPER NINTENDO. An effect is a short score played once over the song, on the
# same voices the Advance plays it on; where the two want one voice, the higher priority sounds on
# it (IR::Tunes.song_rank), and an effect's end lets its voices go. The checked run holds the sound
# log and the DSP's registers to the interpreter's (test/all/vblank/dsl/test_sound_effects.rb plays the
# rest of the rules there); what the voice is told is held here, to fullsnes's numbers worked by hand
# and to the DSP's own envelope (ENVX).
class TestSNESSoundEffects < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  FIRST = 0 << 4 # the first square voice's registers
  SECOND = 1 << 4
  ENVX = 0x8

  # A tune holding C4 on the first square voice from its first frame, and an effect of one E5 note
  # ten frames long on the same voice (150 beats a minute at 24 ticks a beat is a frame a tick),
  # asked for on pass 3 and, with +stop_on+, stop_music on that pass.
  private def played(frames:, effect_priority: 10, stop_on: nil)
    tune = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 96)])])
    hit = Score.new(tempo: 150, priority: effect_priority, parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 10)])])
    game = VBlank.game("EFFECTS", consoles: %i[gba snes]) do
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, { hit: hit }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass < (stop_on || 99)).then { music.play 0 }
        (pass == (stop_on || 99)).then { stop_music }
        (pass == 3).then { sfx.play :hit }
      end
    end
    SNES::CheckedRun.new.run(game.program(console: :snes), frames: frames)
  end

  # The effect outranks the tune and takes its voice: E5, 659 Hz on 32 samples, is pitch
  # 659 * 32 * $1000 / 32000 = 2699, $0A8B; at the part's volume of 12, 96 ($60).
  def test_an_effect_takes_the_tunes_voice
    dsp = played(frames: 6).dsp_registers

    assert_equal [0x8B, 0x0A], [dsp.getbyte(FIRST + 2), dsp.getbyte(FIRST + 3)]
    assert_equal 0x7F, dsp.getbyte(FIRST + ENVX), "sounding at the gain"
  end

  # At its end the effect lets the voice go (ENVX falls to nought), and the tune, whose note it took,
  # stays quiet until its next note: the Advance's player plays the song's notes as they come.
  def test_an_effect_lets_its_voice_go_at_its_end
    run = played(frames: 18)

    assert_equal 0, run.dsp_registers.getbyte(FIRST + ENVX)
    assert_includes run.audio, [:voice, 1, :"sfx.hit", 0, 0]
  end

  # A two-part tune (C4 and E4 on the two square voices) and +effects+, asked for on pass 3, and the
  # tune stopped on pass +stop_on+ and not named again; the block runs each pass with the pass
  # number. The checked run holds every entry to the interpreter.
  private def band(frames:, effects:, stop_on: 99, &body)
    tune = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 4), Note.new(at: 8, key: :D4, length: 40)]),
                                         Part.new(notes: [Note.new(at: 0, key: :E4, length: 48)])])
    game = VBlank.game("BAND", consoles: %i[gba snes]) do
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass < stop_on).then { music.play 0 }
        (pass == stop_on).then { stop_music }
        (pass == 3).then { sfx.play 0 }
        instance_exec(pass, &body) if body
      end
    end
    SNES::CheckedRun.new.run(game.program(console: :snes), frames: frames)
  end

  # An effect takes the first part's voice, so that part is no longer held for a new level; its next
  # note, after the effect, holds it again, after the second part (Reference::Player's @sounding
  # keeps the order keys came in). A new level then reaches the second part first.
  def test_a_new_level_reaches_held_notes_in_the_order_they_took_their_voices_again
    hit = Score.new(tempo: 150, priority: 10, parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 3)])])
    run = band(frames: 16, effects: [hit]) { |pass| (pass == 14).then { music_volume 50 } }

    assert_equal [[:loudness, 2, 6], [:loudness, 1, 6]], run.audio.select { |entry| entry.first == :loudness }.last(2)
  end

  # An effect of a wave part then a square part ends, letting go of its voices in the order each was
  # first held — the first square voice, which the tune held from its start, before the wave voice
  # it took itself — not the order of its parts.
  def test_an_effects_end_lets_go_in_the_order_the_voices_were_first_held
    hit = Score.new(tempo: 150, priority: 10, parts: [Part.new(plays: :sine, notes: [Note.new(at: 0, key: :A3, length: 3)]),
                                                     Part.new(notes: [Note.new(at: 0, key: :E5, length: 3)])])
    run = band(frames: 10, effects: [hit])
    released = run.audio.select { |entry| entry.first == :voice && entry[2] == :"sfx.0" && entry[3].zero? }

    assert_equal [1, 3], released.map { |entry| entry[1] }
  end

  # Stopping a two-part tune whose first voice an effect holds lets go of the second only: the effect
  # sounds on (ENVX at the gain), the tune's other voice falls silent.
  def test_stopping_the_tune_lets_go_of_its_voices_but_the_effects
    hit = Score.new(tempo: 150, priority: 10, parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 20)])])
    dsp = band(frames: 8, effects: [hit], stop_on: 5).dsp_registers

    assert_equal 0x7F, dsp.getbyte(FIRST + ENVX), "the effect's voice"
    assert_equal 0, dsp.getbyte(SECOND + ENVX), "the tune's other voice"
  end

  # stop_music lets go of the tune's voices but not one an effect holds: the effect sounds on.
  def test_stop_music_leaves_an_effect_sounding
    dsp = played(frames: 7, stop_on: 5).dsp_registers

    assert_equal 0x7F, dsp.getbyte(FIRST + ENVX)
    assert_equal [0x8B, 0x0A], [dsp.getbyte(FIRST + 2), dsp.getbyte(FIRST + 3)]
  end

  # A tune that never plays a note — its one voice held by an effect from its first frame — still
  # stops as itself. A hum on the wave voice plays, an effect takes the first square voice, a lead on
  # that voice takes over from the hum and is silent under the effect, the game's own wave plays,
  # and stop_music stops the lead, which holds no voice: the game's wave sounds on.
  def test_stopping_a_tune_that_played_no_note_leaves_the_wave_sounding
    hum = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 96)], plays: :triangle)])
    lead = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 96)])])
    hit = Score.new(tempo: 150, priority: 10, parts: [Part.new(notes: [Note.new(at: 0, key: :E5, length: 60)])])
    game = VBlank.game("SILENT", consoles: %i[gba snes]) do
      enable_sound
      music = songs :music, [hum, lead]
      sfx = sound_effects :sfx, { hit: hit }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then { music.play 0 }
        (pass == 3).then { sfx.play :hit }
        (pass == 5).then { music.play 1 }
        (pass == 7).then { wave :sine, :A4 }
        (pass == 9).then { stop_music }
      end
    end
    dsp = SNES::CheckedRun.new.run(game.program(console: :snes), frames: 12).dsp_registers

    assert_equal 0x7F, dsp.getbyte((SNES::DSPWrites::WAVE_VOICE << 4) + ENVX), "the game's wave"
  end

  # The cartridge says which tune a stop stopped, and the interpreter's log says it too wherever the
  # tune logged a note since the last stop: there the two must agree. A stop of :hum after the lead's
  # note is the cartridge stopping the wrong tune; an effect's note says nothing of the tune; and with
  # no note since the last stop, the cartridge's word is all there is.
  def test_a_stop_naming_another_tune_than_the_one_playing_is_caught
    dsp = SNES::DSPWrites
    voicing = dsp::Voicing.new(effects: [:"sfx.hit"])
    lead = [[:note, :lead, 262], [:voice, 1, :lead, 262, 12]]

    assert_equal 2, dsp.misnamed_stop([*lead, [:stop_music, :hum]], voicing), "the lead's note, then :hum stopped"
    assert_nil dsp.misnamed_stop([*lead, [:stop_music, :lead]], voicing), "the lead stopped"
    assert_nil dsp.misnamed_stop([*lead, [:note, :"sfx.hit", 659], [:stop_music, :lead]], voicing), "an effect's note between"
    assert_nil dsp.misnamed_stop([*lead, [:stop_music, :lead], [:stop_music, :hum]], voicing), "no note since the last stop"
  end
end
