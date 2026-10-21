# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE TESTS OF ruby_gba/audio/test_song_console_voices.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A SONG PART ON THE WAVE VOICE AND ON THE NOISE VOICE — the console's other two.
#
# A part played the square wave or a recorded instrument, and the console had two more voices a
# tune could use and did not: the wave voice, which loops a short waveform (rounder than a square
# wave, and it reaches an octave lower), and the noise voice, which makes a hiss (the drums).
#
# WHAT THEY ARE WORTH is that they cost NO mixer voice. A part that plays a recording keeps one
# of the mixer's voices for as long as its note sounds; these two the console makes itself. So a
# busy song reaches for them before it reaches for another recording, and the voices it does not
# spend stay free for the game's own sounds.
class TestSongConsoleVoicesOnTheAdvance < Minitest::Test
  include RubyGBA::Console::Hardware

  Registers = RubyGBA::Audio::Sound::Registers

  # A tune whose parts cover every voice there is: two square, one wave, one noise, one recorded.
  private def every_voice_game(frames: 60)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :full do
        tempo 150 # a quarter is 24 frames
        voice(:lead) { note :C5, :whole }
        voice(:bass) { note :C3, :whole }
        voice(:pad, plays: :triangle) { note :C2, :whole }
        voice(:drums, plays: :noise) { note :C2, :quarter; note :C5, :quarter }
        voice(:keys, plays: :piano) { note :E4, :whole }
      end
      play_song :full
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # --- the interpreter ---

  # The interpreter logs a song's wave and noise notes the way it logs the `wave` and `noise`
  # VERBS, because they really are the same voice — so one read of the log answers both.
  private def logged(program, frames: 6)
    game_player.run(program, frames: frames).audio
  end

  def test_a_wave_part_sounds_its_waveform_on_the_interpreter
    played = logged(every_voice_game).select { |entry| entry.first == :wave }.map(&:last)

    refute_empty played, "the pad part sounded the wave voice"
    assert_equal :triangle, played.first[:shape], "at the timbre the part named"
    assert_equal RubyGBA::Audio::Music::NOTE_FREQUENCIES[:C2], played.first[:frequency]
  end

  def test_a_noise_part_sounds_a_hit_on_the_interpreter
    hits = logged(every_voice_game).select { |entry| entry.first == :noise }.map(&:last).compact

    refute_empty hits, "the drum part hit the noise voice"
    assert_equal RubyGBA::Audio::Music::NOTE_FREQUENCIES[:C2], hits.first[:pitch]
    assert_equal :fast, hits.first[:decay], "a drum hit rings out rather than being held"
  end

  # THE POINT OF THE WHOLE THING. Five parts, and only the one playing a recording keeps a
  # mixer voice — so a tune with a pad and drums leaves fifteen of the sixteen for the game.
  def test_only_the_recorded_part_keeps_a_mixer_voice
    i = game_player.run(every_voice_game, frames: 6)

    assert_equal [:piano], i.active_samples
    assert_equal 1, i.peak_voices, "the wave and noise parts took none"
  end

  # --- the console ---

  # Wave RAM as its eight halfwords. Read by the word, since a halfword read at an odd offset
  # is not aligned.
  private def wave_ram(probe)
    (0...(Registers.wavetable_halfwords(:triangle).length / 2)).flat_map do |word|
      value = probe.read32(REG_WAVE_RAM + (word * 4))
      [value & 0xFFFF, (value >> 16) & 0xFFFF]
    end
  end

  # Both backends sound the same thing, which is the contract that makes the interpreter an
  # oracle for this at all.
  def test_both_backends_agree_about_what_the_wave_voice_plays
    program = every_voice_game
    interpreted = logged(program, frames: 8).select { |e| e.first == :wave }.map(&:last).first
    v = assert_emulator_loads_rom(assemble_rom(program, name: "VOICES"), frames: 10)

    assert_equal Registers.wave_rate(interpreted[:frequency]), v.wave_rate
  end

  # --- a note on the noise voice ---

  # --- what `plays:` accepts ---

  private def part_for(plays)
    RubyGBA::Audio::Music::VoiceContext.new(RubyGBA::Audio::Music::SongContext.new, plays: plays).to_voice
  end

  # --- the noise part's own settings ---

  # The same tune twice: one square-wave part, optionally told how a drum hit would fade.
  private def square_song(fade: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        voice :lead do |v|
          if fade
            v.decay :slow
            v.metallic true
          end
          v.note :C4, :quarter
        end
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # --- a waveform of the game's own, rather than one of the names ---

  # THE NAMED SHAPES ARE A CONVENIENCE, NOT THE TRUTH. The console's wave voice is 32 steps of
  # four bits that a game writes, so a game whose music came from somewhere else — decoded out
  # of another cartridge — arrives holding those 32 numbers, and no name would be the waveform
  # it actually has. A 50% pulse is the common case and is none of :sine, :triangle, :sawtooth
  # or :square: played as a triangle it is a different instrument.
  PULSE_50 = ([15] * 16 + [0] * 16).freeze

  # One part on the wave voice, playing whatever it is given.
  private def pad_song(plays)
    b = Builder.new
    shape = plays
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) { voice(:pad, plays: shape) { note :C4, :whole } }
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Wave RAM as the console really holds it — the eight halfwords of the bank the CPU is shown.
  private def wave_ram_of(program, name)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: name, code: "BWAV", maker: "01",
                                               built: backend.build_record(program))
    v = assert_emulator_loads_rom(rom, frames: 6)
    (0...Registers.wavetable_halfwords(:sine).length).map { |i| v.mem16(REG_WAVE_RAM + (i * 2)) }
  end

  # --- a Score says it the same way ---

end
