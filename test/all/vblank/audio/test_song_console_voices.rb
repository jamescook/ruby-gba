# frozen_string_literal: true

require "test_helper"

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
#
# What the Advance's cartridge holds and sounds — its wave voice's registers, its wave memory —
# is read in the emulator in
# test/lowering/gba/vblank/audio/test_song_console_voices_cartridge.rb, which shares the
# waveform and the game kept here in SongConsoleVoicesGames.
module SongConsoleVoicesGames
  include SharedConstants # Builder, which a game below names from inside the module

  Registers = VBlank::Audio::Sound::Registers

  # THE NAMED SHAPES ARE A CONVENIENCE, NOT THE TRUTH. The console's wave voice is 32 steps of
  # four bits that a game writes, so a game whose music came from somewhere else — decoded out
  # of another cartridge — arrives holding those 32 numbers, and no name would be the waveform
  # it actually has. A 50% pulse is the common case and is none of :sine, :triangle, :sawtooth
  # or :square: played as a triangle it is a different instrument.
  PULSE_50 = Ractor.make_shareable([15] * 16 + [0] * 16)

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
end

class TestSongConsoleVoices < Minitest::Test
  include VBlank::Console::Hardware
  include SongConsoleVoicesGames

  # --- the interpreter ---

  # The interpreter logs a song's wave and noise notes the way it logs the `wave` and `noise`
  # VERBS, because they really are the same voice — so one read of the log answers both.
  private def logged(program, frames: 6)
    game_player.run(program, frames: frames).audio
  end

  # --- a note on the noise voice ---

  # A hiss has no pitch the way a melody does; what it has is a CLOCK, and a faster clock is a
  # higher, thinner hiss. So a note picks the clock nearest to it — which is what makes a low
  # note a kick and a high one a hat, and it has to be monotonic for that to be true.
  def test_a_higher_note_gives_a_faster_hiss
    low = Registers.noise_frequency(*Registers.noise_clock(VBlank::Audio::Music::NOTE_FREQUENCIES[:C2]))
    high = Registers.noise_frequency(*Registers.noise_clock(VBlank::Audio::Music::NOTE_FREQUENCIES[:C5]))

    assert_operator high, :>, low, "a higher note sits higher on the ladder"
  end

  def test_the_clock_chosen_is_the_nearest_one_there_is
    want = 1000
    divisor, shift = Registers.noise_clock(want)
    best = (Registers.noise_frequency(divisor, shift) - want).abs
    every = Registers::NOISE_DIVISORS.product(Registers::NOISE_SHIFT_RANGE.to_a)
                                     .map { |d, s| (Registers.noise_frequency(d, s) - want).abs }.min

    assert_in_delta best, every, 0.001
  end

  # A rest silences the voice rather than leaving the last hit ringing.
  def test_a_rest_on_either_voice_silences_it
    assert_equal [[REG_SOUND3CNT_H, 0], [REG_SOUND3CNT_X, 0]],
                 Registers.wave_note(frequency: 0, volume: 12)
    assert_equal [[REG_SOUND4CNT_L, 0], [REG_SOUND4CNT_H, 0x8000]],
                 Registers.noise_note(frequency: 0, decay: :fast, volume: 12, metallic: false)
  end

  # --- what `plays:` accepts ---

  private def part_for(plays)
    VBlank::Audio::Music::VoiceContext.new(VBlank::Audio::Music::SongContext.new, plays: plays).to_voice
  end

  def test_plays_names_a_voice_by_what_it_sounds_like
    assert_equal :triangle, part_for(:wave).wave, "bare :wave is the middle timbre"
    assert_equal :sine, part_for(:sine).wave
    assert part_for(:noise).noise
    assert_equal :piano, part_for(:piano).instrument
    assert_equal :square, VBlank::IR::Tunes.part_kind(part_for(nil))
  end

  # `plays: :square` reads two ways and the wrong reading is silent: the author means "this part
  # plays a square wave", which is what a part does with NO `plays:` — and would get the wave
  # voice instead, a different voice and one of the two the song may be short of.
  def test_plays_square_is_a_friendly_error_naming_both_readings
    error = assert_raises(ArgumentError) { part_for(:square) }

    assert_match(/remove `plays:` from this part/, error.message)
    assert_match(/`plays: :wave`/, error.message)
  end

  def test_plays_something_that_is_not_a_name_says_what_it_takes
    error = assert_raises(ArgumentError) { part_for(42) }

    assert_match(/:wave/, error.message)
    assert_match(/:noise/, error.message)
  end

  # --- the noise part's own settings ---

  def test_a_noise_part_says_how_its_hits_fade_and_whether_they_rattle
    part = VBlank::Audio::Music::VoiceContext.new(VBlank::Audio::Music::SongContext.new, plays: :noise)
    part.decay :slow
    part.metallic true
    part.note :C3, :quarter

    assert_equal :slow, part.to_voice.decay
    assert part.to_voice.metallic
  end

  # --- a waveform of the game's own, rather than one of the names ---

  # The interpreter carries it too, so both backends are told the same waveform.
  def test_the_interpreter_plays_the_waveform_it_was_given
    played = logged(pad_song(PULSE_50)).select { |entry| entry.first == :wave }.map(&:last).compact

    refute_empty played
    assert_equal PULSE_50, played.first[:shape]
  end

  # A waveform that cannot be one is refused at the line that wrote it, not at the cartridge.
  def test_a_waveform_the_console_cannot_hold_is_a_friendly_error
    short = assert_raises(ArgumentError) { pad_song([15] * 8) }
    assert_match(/32 steps/, short.message)

    loud = assert_raises(ArgumentError) { pad_song(([15] * 31) + [99]) }
    assert_match(/0 to 15/, loud.message)
  end

  # --- a Score says it the same way ---

  def test_a_score_part_names_the_console_voices_too
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: 48)]
    pad = VBlank::Audio::Score::Part.new(plays: :wave, notes: notes)
    drums = VBlank::Audio::Score::Part.new(plays: :noise, notes: notes, decay: :slow, metallic: true)
    song = VBlank::Audio::Score.new(parts: [pad, drums]).to_song

    assert_equal :triangle, song[:voices].first.wave
    assert song[:voices].last.noise
    assert_equal :slow, song[:voices].last.decay
    assert_nil song[:voices].first.instrument, "a part on the console's own voice plays no recording"
  end
end
