# frozen_string_literal: true

require "test_helper"

# A TUNE KEEPS ITS OWN TIME ON THE ADVANCE'S CARTRIDGE, genuinely late, and heard in the emulator:
# the sound it makes frame by frame, and how many frames a pass really took. The music's timing
# asked of every run is in test/all/vblank/audio/test_music_keeps_time.rb.
class TestMusicKeepsTimeCartridge < Minitest::Test
  # --- the console, genuinely late ---

  # A note held for six frames, then six frames of silence, round and round — so how many
  # times the sound starts in a run is how fast the tune is going.
  FRAMES = 72
  BEATS = FRAMES / 12

  # HOW MUCH WORK MAKES A PASS LATE on this emulator, measured, and each picked from the middle
  # of the range that gives it — about twenty-five thousand steps is a frame of this game. The
  # test asserts what it got, so a change in the machine shows up as a failed assumption rather
  # than a test quietly measuring nothing.
  BURNS = { 1 => 0, 2 => 35_000, 3 => 60_000 }.freeze

  private def beat_game(burn)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :beat do
        tempo 600 # a quarter is six frames
        note :C5, :quarter
        rest :quarter
      end
      spin = var :spin, 0
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        play_song :beat
        repeat(burn) { spin.add! 1 }
      end
    end
    b.finalize_program
    b.program
  end

  # How many frames a pass took on the console, and how many times the sound started.
  private def beats_heard(burn)
    backend = GBA.new
    program = beat_game(burn)
    rom = ROM.assemble(backend.lower(program), title: "MUSTIME", code: "ZMST", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: FRAMES, vars: backend.var_addresses)
    energy = console.audio_energy_by_frame
    loud = energy.map { |e| e > energy.max / 4 }
    onsets = loud.each_index.count { |n| loud[n] && (n.zero? || !loud[n - 1]) }
    { per_pass: FRAMES / console.var(:passes).to_f, beats: onsets }
  end

  def test_a_late_game_plays_its_tune_at_the_tempo_it_was_written
    on_time = beats_heard(BURNS.fetch(1))

    assert_in_delta 1.0, on_time[:per_pass], 0.1, "the control game should keep up"
    assert_in_delta BEATS, on_time[:beats], 1, "a beat every twelve frames, over #{FRAMES} frames"

    BURNS.each do |frames_a_pass, burn|
      late = beats_heard(burn)

      assert_in_delta frames_a_pass, late[:per_pass], 0.2,
                      "burn #{burn} was meant to give #{frames_a_pass} frames a pass"
      assert_in_delta on_time[:beats], late[:beats], 1,
                      "at #{frames_a_pass} frames a pass the tune beat #{late[:beats]} times " \
                      "instead of #{on_time[:beats]} — it is being stepped by the game loop"
    end
  end

  # A held note, named for the first twenty passes and then stopped: the console sounds it, then
  # goes quiet and stays quiet.
  def test_stopping_the_music_silences_the_console
    backend = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :drone do
        note :C5, :whole
        note :C5, :whole
      end
      passes = var :passes, 0
      game_loop do
        passes.add! 1
        (passes < 20).then { play_song :drone }.else { stop_music }
      end
    end
    b.finalize_program
    rom = ROM.assemble(backend.lower(b.program), title: "MUSSTOP", code: "ZMSS", maker: "01")
    energy = assert_emulator_loads_rom(rom, frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds while it is named (#{energy.inspect})"
    assert_operator energy[30..].max, :<, loud, "and is gone once the music stops (#{energy.inspect})"
  end

  # The sound-effect voice is also the second music voice, so silencing music used to reach it
  # too — and a game writing `stop_music` every frame (the music setting turned off) cut every
  # beep after a single frame. Saying it while nothing plays now touches nothing.
  def test_a_beep_rings_out_while_the_game_keeps_saying_no_music
    backend = GBA.new
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :beat do
        note :C5, :quarter
      end
      started = var :started, 0
      game_loop do
        stop_music
        (started == 0).then do
          started.set! 1
          beep 440, decay: :slow
        end
      end
    end
    b.finalize_program
    rom = ROM.assemble(backend.lower(b.program), title: "MUSBEEP", code: "ZMSB", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 20)
    energy = console.audio_energy_by_frame
    sounding = energy.count { |e| e > energy.max / 4 }

    assert_operator sounding, :>=, 5, "a slow-fading beep should ring for a good while (#{energy.inspect})"
  end
end
