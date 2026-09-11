# frozen_string_literal: true

require "test_helper"

# A TUNE KEEPS ITS OWN TIME, whatever the game does — the same promise the mixer makes
# (test_mixer_keeps_time.rb), for the same reason. A tempo is a fact about the clock on the
# wall, not about how long the game took to think, so a game too heavy for a frame still plays
# its music at the speed it was written.
#
# Which is why `play_song` names the tune that is playing rather than stepping it along: a tune
# stepped once per pass of the game loop plays at half speed in a game that takes two frames a
# pass, and at no speed at all in a frame whose branch skipped the call.
class TestMusicKeepsTime < Minitest::Test
  def notes(interpreter)
    interpreter.audio.select { |entry| entry[0] == :note }.map(&:last)
  end

  # A note every ten frames — C4, E4, G4 — so which notes a run heard says how far into the tune
  # it got. The block is the loop's body, handed how many passes have run.
  def scale_game(&loop_body)
    loop_body ||= proc { play_song :scale }
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        tempo 360 # a quarter is ten frames
        note :C4, :quarter
        note :E4, :quarter
        note :G4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add 1
        instance_exec(pass, &loop_body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  C4 = RubyGBA::Music::NOTE_FREQUENCIES[:C4]
  E4 = RubyGBA::Music::NOTE_FREQUENCIES[:E4]
  G4 = RubyGBA::Music::NOTE_FREQUENCIES[:G4]

  # --- the interpreter, told that a pass ran late ---

  def test_a_late_game_hears_the_same_notes_in_the_same_time
    on_time = Reference.new.run(scale_game, frames: 30)
    late = Reference.new.frames_each_pass { 2 }.run(scale_game, frames: 15)

    assert_equal [C4, E4, G4], notes(on_time), "thirty frames of the tune reach its third note"
    assert_equal notes(on_time), notes(late),
                 "fifteen passes of two frames each are thirty frames too, so the tune is as far along"
  end

  def test_a_tune_named_only_on_some_frames_keeps_its_tempo
    every_frame = Reference.new.run(scale_game, frames: 30)
    every_other = Reference.new.run(scale_game { |pass| (pass % 2 == 0).then { play_song :scale } }, frames: 30)

    assert_equal notes(every_frame), notes(every_other),
                 "a tune that is named on half the frames is still playing on the other half"
  end

  def test_naming_the_tune_twice_in_one_frame_is_the_same_as_once
    once = Reference.new.run(scale_game, frames: 30)
    twice = Reference.new.run(scale_game { play_song :scale; play_song :scale }, frames: 30)

    assert_equal notes(once), notes(twice)
  end

  # --- switching tunes, which is what a jukebox or a scene change does ---

  def two_tunes_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :first do
        tempo 360
        note :C4, :quarter
        note :E4, :quarter
        note :G4, :quarter
      end
      song :second do
        tempo 360
        note :A4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add 1
        # the first tune, then the second from pass 16, then back to the first from pass 22
        ((pass >= 16) & (pass < 22)).then { play_song :second }.else { play_song :first }
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_coming_back_to_a_tune_starts_it_from_the_beginning
    heard = notes(Reference.new.run(two_tunes_game, frames: 30))

    # C4 and E4 (the first tune reaches its second note), A4 (the second), then the first tune
    # again FROM ITS DOWNBEAT — not from wherever it had got to when it was left.
    assert_equal [C4, E4, RubyGBA::Music::NOTE_FREQUENCIES[:A4], C4], heard
  end

  def test_stopping_the_music_silences_it_and_starting_again_starts_over
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        tempo 360
        note :C4, :quarter
        note :E4, :quarter
      end
      pass = var :pass, 0
      game_loop do
        pass.add 1
        ((pass >= 5) & (pass < 8)).then { stop_music }.else { play_song :scale }
      end
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program, frames: 12)

    assert_equal [:note, :stop_music, :note], i.audio.filter_map { |e| e[0] if %i[note stop_music].include?(e[0]) },
                 "the tune stops once, then starts over from its downbeat"
    assert_equal [C4, C4], notes(i)
  end

  # Saying "no music" while none is playing does nothing at all. A game that writes it every frame
  # a setting is off — pong's music row does — must not keep reaching for the sound hardware,
  # because the voice it would silence is the one its sound effects play on.
  def test_saying_no_music_while_none_plays_does_nothing
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :scale do
        note :C4, :quarter
      end
      game_loop { stop_music }
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program, frames: 10)

    assert_empty i.audio.select { |e| e[0] == :stop_music }
  end

  # --- the console, genuinely late ---

  # A note held for six frames, then six frames of silence, round and round — so how many
  # times the sound starts in a run is how fast the tune is going.
  FRAMES = 72
  BEATS = FRAMES / 12

  # HOW MUCH WORK MAKES A PASS LATE on this emulator, measured, and each picked from the middle
  # of the range that gives it — about twenty thousand steps is a frame of this game. The test
  # asserts what it got, so a change in the machine shows up as a failed assumption rather than
  # a test quietly measuring nothing.
  BURNS = { 1 => 0, 2 => 30_000, 3 => 50_000 }.freeze

  def beat_game(burn)
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
        passes.add 1
        play_song :beat
        repeat(burn) { spin.add 1 }
      end
    end
    b.emit_pending_functions
    b.program
  end

  # How many frames a pass took on the console, and how many times the sound started.
  def beats_heard(burn)
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
        passes.add 1
        (passes < 20).then { play_song :drone }.else { stop_music }
      end
    end
    b.emit_pending_functions
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
          started.set 1
          beep 440, decay: :slow
        end
      end
    end
    b.emit_pending_functions
    rom = ROM.assemble(backend.lower(b.program), title: "MUSBEEP", code: "ZMSB", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 20)
    energy = console.audio_energy_by_frame
    sounding = energy.count { |e| e > energy.max / 4 }

    assert_operator sounding, :>=, 5, "a slow-fading beep should ring for a good while (#{energy.inspect})"
  end
end
