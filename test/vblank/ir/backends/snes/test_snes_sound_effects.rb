# frozen_string_literal: true

require "test_helper"

# SOUND EFFECTS ON A SUPER NINTENDO. An effect is a short score played once over the song, on the
# same voices the Advance plays it on; where the two want one voice, the higher priority sounds on
# it (IR::Tunes.song_rank), and an effect's end lets its voices go. The checked run holds the sound
# log and the DSP's registers to the interpreter's (test/vblank/dsl/test_sound_effects.rb plays the
# rest of the rules there); what the voice is told is held here, to fullsnes's numbers worked by hand
# and to the DSP's own envelope (ENVX).
class TestSNESSoundEffects < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  FIRST = 0 << 4 # the first square voice's registers
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

  # stop_music lets go of the tune's voices but not one an effect holds: the effect sounds on.
  def test_stop_music_leaves_an_effect_sounding
    dsp = played(frames: 7, stop_on: 5).dsp_registers

    assert_equal 0x7F, dsp.getbyte(FIRST + ENVX)
    assert_equal [0x8B, 0x0A], [dsp.getbyte(FIRST + 2), dsp.getbyte(FIRST + 3)]
  end
end
