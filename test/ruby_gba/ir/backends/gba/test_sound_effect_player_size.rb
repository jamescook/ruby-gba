# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A SOUND EFFECT'S VOICES COST THE ROUTINE THE SCREEN'S INTERRUPT RUNS. That routine is
# weighed for the console's quick memory against everything else a frame runs, and kept there
# first, so every byte it grows by is a byte some routine of the game's own no longer has.
#
# The effects' player starts an effect, plays its notes and lets its voices go, and all of that
# is written out once for every voice the effects use between them — so it used to grow the day
# one effect used a voice no other did: a fanfare on the wave voice, a line read on two
# recordings. A cartridge one scene from the edge of the quick memory lost a routine it ran every
# frame to two new effects. Yet that code runs only on the frames an effect sounds. So it is a
# routine of its own, kept in the cartridge, and the routine the interrupt runs keeps only the
# walk that asks each effect whether it has anything to do.
#
# What the interrupt's routine still grows by is the music's, and is not counted here: a song's
# lane on a voice an effect can take checks who holds it, and recorded effects make the mixer's
# voices rank against each other. The music player keeps both square voices as lanes even in a
# game with no song, so this game's effects leave them out.
class TestSoundEffectPlayerSize < Minitest::Test
  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note

  NOTES = [Note.new(at: 0, key: :C4, length: 6), Note.new(at: 8, key: :E4, length: 6)].freeze
  DOOR = Score.new(tempo: 150, parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, hz: 131_072, length: 6)])])
  LINE = Score.new(tempo: 150, parts: [Part.new(plays: :voice, notes: NOTES)])
  CHORUS = Score.new(tempo: 150, parts: [Part.new(plays: :wave, notes: NOTES), Part.new(plays: :voice, notes: NOTES),
                                         Part.new(plays: :voice, notes: NOTES)])

  # A game with no song whose effects are +effects+, asked for one after another.
  private def program(effects)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :voice, pcm: [20, -20] * 400, rate: 8000, note: :C4
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        effects.each_index { |n| (pass == 3 + (20 * n)).then { sfx.play n } }
      end
    end
    b.finalize_program
    b.program
  end

  private def interrupt_routine_bytes(program)
    backend = GBA.new
    backend.lower(program)
    backend.func_sizes.fetch(GBA::Placement::IRQ_ROUTINE)
  end

  # THE SONG'S WAVE LANE STILL REACHES WHAT PUTS A WAVEFORM IN PLACE. The effects' notes and the
  # song's both call it, so it stays inside the interrupt's routine while the effects' step moves
  # out — and a cartridge whose interrupt runs from the quick memory builds, rather than a plain
  # jump from the copy landing in whatever the quick memory holds where the routine used to be.
  def test_a_song_and_an_effect_on_the_wave_voice_build_with_the_interrupt_in_quick_memory
    # A timer ticking twice a frame enters the interrupt's routine more than once a frame, which is
    # what earns it its place in the quick memory.
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :triangle, notes: NOTES)])
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(plays: :sawtooth, notes: NOTES)])
    game = RubyGBA.game "WAVES" do
      screen :bitmap
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, [hit]
      pass = var :pass, 0
      ticks = var :ticks, 0
      timer(:beat, per_second: 120).on_tick { ticks.add! 1 }
      game_loop do
        pass.add! 1
        music.play 0
        (pass == 10).then { sfx.play 0 }
      end
    end
    rom = game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)

    assert_includes rom.built.placement.funcs, GBA::Placement::IRQ_ROUTINE, "the interrupt's routine runs from the quick memory"
  end

  def test_an_effect_on_voices_no_other_effect_uses_adds_nothing_to_the_interrupt_routine
    before = interrupt_routine_bytes(program([DOOR, LINE]))
    after = interrupt_routine_bytes(program([DOOR, LINE, CHORUS]))

    assert_equal before, after, "a door and a line keep a #{before}-byte routine, and a chorus on the wave voice " \
                                "and two recordings beside them a #{after}-byte one"
  end
end
