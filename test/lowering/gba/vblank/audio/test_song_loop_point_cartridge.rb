# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_song_loop_point"

# A SONG WITH AN INTRODUCTION, ON THE ADVANCE'S CARTRIDGE: what its music voice is doing at the
# loop point, read in the emulator. A song block's loop point and the friendly errors are in
# test/all/vblank/audio/test_song_loop_point.rb.
class TestSongLoopPointCartridge < Minitest::Test
  include SongLoopPointGames

  STEP_ONE = GBA::Mixer::STEP_ONE

  private def game(song)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      # Five seconds of a steady tone, so a note is still sounding wherever a test looks.
      instrument :organ, pcm: [60, -60] * 20_000, rate: 8000, note: :C4
      music = songs :music, [song]
      game_loop { music.play 0 }
    end
    b.finalize_program
    b.program
  end

  # What the console's music voice is doing +frames+ in: [step, how far into the recording], or
  # nil when it is silent.
  private def console_voice(song, frames:)
    voice = assert_emulator_loads_rom(assemble_rom(game(song), name: "LOOPPT"), frames: frames).voices.first
    voice && [voice.step, voice.position]
  end

  # What a note's step comes out as. It carries two things: the note's pitch against the one
  # the organ was recorded at, and the resampling — the mix runs at a rate the sound hardware
  # can sustain rather than at the rate of the recording (Console::SampleClock), so a note
  # at the recorded pitch is not a step of 1.0. Asked of the same function the build asks.
  RECORDED_AT = 8000
  private def step(key)
    resample = RECORDED_AT.to_f / VBlank::Console::ADVANCE.sample_clock(RECORDED_AT).rate
    (NOTES[key].to_f / NOTES[:C4] * resample * STEP_ONE).round
  end

  # --- the introduction plays once ---

  # On the console: a little way into the second time round, a song that looped from its start
  # would be back in its introduction. This one is in its loop.
  def test_the_console_goes_back_to_the_loop_point
    at_first, = console_voice(score(part(*INTRO_THEN_LOOP)), frames: 12)
    second_time, = console_voice(score(part(*INTRO_THEN_LOOP)), frames: 84)

    assert_in_delta step(:C4), at_first, 2, "the introduction, the first time"
    assert_in_delta step(:E4), second_time, 2, "the loop, not the introduction again"
  end

  # --- a note held across the loop point ---

  # C4 starts in the introduction and is still sounding when the loop point comes; the song
  # ends on G4. So every time round, C4 has to be sounded again at the loop point.
  HELD = [[0, :C4], [48, :G4]].freeze

  def test_the_console_sounds_the_held_note_at_the_loop
    second_time, = console_voice(score(part(*HELD)), frames: 84)

    assert_in_delta step(:C4), second_time, 2, "the held note, not the note the song ended on"
  end

  # The first time round the held note is not struck again at the loop point: 40 frames in it is
  # 40 frames into its recording, where striking it again at frame 24 would put it 16 in.
  def test_the_console_does_not_strike_the_held_note_again_the_first_time
    _, position = console_voice(score(part(*HELD)), frames: 44)

    assert_operator position, :>, 8000 / 2, "a sound more than half a second in (#{position} samples)"
  end

  # --- a part that is silent at the loop point ---

  # This part comes in after the loop point and is still sounding at the end. Coming round, it
  # has to go quiet until its note, as it was the first time.
  def test_a_part_silent_at_the_loop_point_is_silenced_there
    assert_nil console_voice(score(part([48, :G4])), frames: 84), "silent between the loop point and its note"
  end

  # A song that loops from its start is the same rule: a part that comes in late no longer rings
  # on into the start of the song each time round.
  def test_a_part_that_comes_in_late_is_silent_each_time_the_song_starts_again
    assert_nil console_voice(score(part([36, :G4]), loop_from: nil), frames: 84)
  end
end
