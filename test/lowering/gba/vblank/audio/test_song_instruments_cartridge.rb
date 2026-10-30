# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/audio/test_song_instruments_on_the_advance"

# A song part that plays a recorded instrument, as the Advance's cartridge plays it: the mixer's
# voices read back in the emulator. The surface — the friendly errors and the warnings — is in
# test/all/vblank/audio/test_song_instruments.rb, and what the run's own player sounds is in
# test/console/gba/vblank/audio/test_song_instruments_on_the_advance.rb.
class TestSongInstrumentsCartridge < Minitest::Test
  include SongInstrumentsSharing

  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES
  STEP_ONE = GBA::Mixer::STEP_ONE

  # A piano recorded at C4, a second long — longer than any note here, so it is the next event
  # that ends a note rather than the recording running out.
  private def piano_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :tune do
        tempo 360 # a quarter is ten frames
        voice :melody, plays: :piano do
          note :C4, :quarter
          rest :quarter
          note :G4, :quarter
        end
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  private def console_steps_at(frames)
    rom = assemble_rom(piano_game, name: "SONGINST")
    assert_emulator_loads_rom(rom, frames: frames).voices.map { |v| [v.sample, v.step] }
  end

  # A step carries the note's pitch against the recorded one AND the resampling: the mix runs
  # at a rate the sound hardware can sustain (Console::SampleClock) rather than at the rate
  # the piano was recorded at, so a note at the recorded pitch is not a step of 1.0.
  RECORDED_AT = 8000
  private def step_for(note)
    resample = RECORDED_AT.to_f / VBlank::Console::ADVANCE.sample_clock(RECORDED_AT).rate
    (NOTES[note].to_f / NOTES[:C4] * resample * STEP_ONE).round
  end

  def test_the_console_plays_each_note_at_its_pitch
    first = console_steps_at(6)
    assert_equal 1, first.size, "one voice: the melody's C4 (#{first.inspect})"
    assert_equal :piano, first[0][0]
    assert_in_delta step_for(:C4), first[0][1], 2

    assert_empty console_steps_at(16), "the rest silenced it"

    third = console_steps_at(26)
    assert_equal :piano, third[0][0]
    assert_in_delta step_for(:G4), third[0][1], 2, "the G4 reads the recording faster"
  end

  # --- the voices, which the music and the game's own sounds share ---

  # What the cartridge has sounding, +frames+ in.
  private def sounding_on_the_console(program, frames:)
    assert_emulator_loads_rom(assemble_rom(program, name: "SONGSHARE"), frames: frames + 2).sounding
  end

  # A note already sounding keeps its voice, and the game's burst gets every voice left.
  def test_a_sounding_note_keeps_its_voice_and_the_game_gets_the_rest
    assert_equal [:piano] + clip_names(0...(VOICES - 1)), sounding_on_the_console(note_held_through_the_burst, frames: 10)
  end

  # A part's next note takes over the voice its last note is still sounding in, rather than
  # taking a second one and leaving the first to ring on underneath it.
  def test_a_parts_next_note_takes_over_its_own_voice
    assert_equal [:piano], sounding_on_the_console(next_note_on_its_own_voice, frames: 40)
  end

  # A part that rests gives its voice up: while it rests, every voice is the game's.
  def test_a_resting_part_lends_its_voice_to_the_game
    assert_equal clip_names(0...VOICES), sounding_on_the_console(resting_part, frames: 50),
                 "all of them the game's, the part resting"
  end

  # THE MOMENT THE VOICES RUN OUT: every voice is the game's when the part's note comes, so the
  # note takes the voice of the game's sound that has played longest.
  def test_a_note_with_no_voice_free_takes_the_one_the_game_started_first
    assert_equal [:piano] + clip_names(1...VOICES), sounding_on_the_console(note_after_the_burst, frames: 40),
                 "s0, the oldest, gave way"
  end

  # ...one that plays once before one that loops, since a loop never ends of its own accord.
  def test_a_sound_that_loops_gives_way_last
    assert_equal [:s0, :piano] + clip_names(2...VOICES),
                 sounding_on_the_console(note_after_the_burst(loop_first: true), frames: 40),
                 "s0 loops, so s1 gave way"
  end
end
