# frozen_string_literal: true

require "test_helper"

# THE SOUND OF A LONG RUN IS THE SOUND OF A SHORT ONE, wherever it was kept. A reader holds
# so many frames of sound in memory and writes the sound before that to a scratch file (see
# RecordedSound), and nothing that asks about the sound can tell which a frame was in. So a
# test here runs one cartridge twice, once with everything in memory and once with room for
# a few frames only, and asks both the same things.
class TestVerifierSound < Minitest::Test
  runs_on :reference

  RecordedSound = RubyGBA::Diagnostics::RecordedSound

  # A tune and not one held note, so that a frame read back out of its place is a different
  # sound from the frame that belongs there.
  private def tune
    game = RubyGBA.game "TUNE" do
      screen :bitmap
      enable_sound
      song(:scale) do
        tempo 480
        note :C4, :quarter
        note :E4, :quarter
        note :G4, :quarter
        note :C5, :quarter
      end
      play_song :scale
      game_loop { wait_vblank }
    end
    game.build_rom(out: nil, err: nil, profile: false)
  end

  # A RecordedSound that also notes in +handed+ how many frames it was given each time:
  # the one thing about a long run that nothing read back afterwards can show.
  private def sound_noting_frames_handed_over(handed, **settings)
    Class.new(RecordedSound) do
      define_method(:keep) do |frames|
        handed << frames.size
        super(frames)
      end
    end.new(**settings)
  end

  def test_run_past_the_sound_held_in_memory_reads_back_the_same_sound
    cartridge = tune
    Dir.mktmpdir("verifier-sound") do |folder|
      in_memory = assert_emulator_loads_rom(cartridge, frames: 43)
      in_file = assert_emulator_loads_rom(cartridge, frames: 43,
                                                     sound: RecordedSound.new(frames_in_memory: 8, folder: folder))

      refute_empty Dir.children(folder), "the reader wrote its sound where it was told to"
      assert_operator in_memory.audio_energy_by_frame.uniq.size, :>, 4, "the tune changes as it plays"
      assert_equal in_memory.audio_samples, in_file.audio_samples, "sample for sample"
      assert_equal in_memory.audio_energy_by_frame, in_file.audio_energy_by_frame, "and frame by frame"
      assert_predicate in_file, :sound?
    end
  end

  # Buttons that change by the frame are handed over a frame at a time, which is the other
  # road sound takes into a reader, and a run goes on being added to after it is first read:
  # five more frames by that road, then eleven with one set of buttons held throughout.
  def test_run_played_one_frame_at_a_time_and_then_stepped_reads_back_the_same_sound
    cartridge = tune
    no_buttons = ->(_frame) { 0 }
    in_memory = assert_emulator_loads_rom(cartridge, frames: 20, keys: no_buttons)
    in_file = assert_emulator_loads_rom(cartridge, frames: 20, keys: no_buttons,
                                                   sound: RecordedSound.new(frames_in_memory: 3))

    [in_memory, in_file].each do |reader|
      reader.step(5)
      reader.step(11, keys: 0)
    end

    assert_equal 36, in_file.audio_energy_by_frame.size
    assert_equal in_memory.audio_samples, in_file.audio_samples
    assert_equal in_memory.audio_energy_by_frame, in_file.audio_energy_by_frame
  end

  # HOW LOUD THE LAST FRAME WAS, ASKED AFTER EVERY FRAME, is what asking once at the end
  # gives, frame for frame — with the sound all in memory, and with most of it in the file.
  def test_asked_after_every_frame_is_what_asking_once_at_the_end_gives
    cartridge = tune
    once = assert_emulator_loads_rom(cartridge, frames: 40).audio_energy_by_frame

    [RecordedSound.new, RecordedSound.new(frames_in_memory: 3)].each do |sound|
      reader = RubyGBA::Diagnostics::Verifier.new(cartridge, frames: 0, sound: sound)
      each_frame = Array.new(40) { reader.step.audio_energy_by_frame.last }
      totals = [reader.audio_energy, reader.sound?]

      assert_operator once.uniq.size, :>, 4, "the tune changes as it plays"
      assert_equal once, each_frame
      assert_equal [once.sum, true], totals
    end
  end

  # The emulator holds the sound of a step until the step ends. So a run of many frames is
  # played as several steps, and no more sound is on its way to the reader at one time than
  # the reader holds.
  def test_long_run_hands_over_no_more_sound_at_once_than_is_held_in_memory
    handed = []
    reader = assert_emulator_loads_rom(tune, frames: 43,
                                             sound: sound_noting_frames_handed_over(handed, frames_in_memory: 8))

    assert_equal [8, 8, 8, 8, 8, 3], handed

    reader.step(20)

    assert_equal [8, 8, 8, 8, 8, 3, 8, 8, 4], handed
  end

  def test_sound_that_is_no_recorded_sound_is_refused
    error = assert_raises(ArgumentError) { RubyGBA::Diagnostics::Verifier.new(tune, sound: 600) }

    assert_match(/sound:/, error.message)
    assert_match(/RecordedSound/, error.message)
    assert_includes error.message, "600"
  end
end
