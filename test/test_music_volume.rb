# frozen_string_literal: true

require "test_helper"

# HOW LOUD THE MUSIC PLAYS, moved while it plays.
#
# A part's volume is written into the song, and until now nothing could change it once the song
# was built. `music_volume` scales every part of whatever song is playing — a settings screen's
# music slider, and the level `fade_music_out` walks down to silence.
class TestMusicVolume < Minitest::Test
  # A song holding one long note at volume 12 — on the first square voice, or on whichever voice
  # +plays+ names — and a game that runs +body+ on each pass with the pass number. The game names
  # the song on every pass, or with +named_once+ on its first pass only and then whenever +body+
  # says so.
  def held_note_game(plays: nil, named_once: false, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      # A recording that holds, so a long note does not run out before the test is over.
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100 if plays == :piano
      song :hold do
        tempo 60
        if plays
          voice(:held, plays: plays) do
            volume 12
            note :C4, :whole
          end
        else
          volume 12
          note :C4, :whole
        end
      end
      pass = var :pass, 0
      game_loop do
        pass.add 1
        named_once ? (pass == 1).then { play_song :hold } : play_song(:hold)
        instance_exec(pass, &body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  # How loud each voice was set, on the frames it was set, from the interpreter:
  # { frame => [[channel, volume 0..15], ...] }. With +stops+, a frame the music stopped on
  # says :stop_music among them.
  def loudness_by_frame(program, frames, stops: false)
    i = Reference.new
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).filter_map do |entry|
        next entry.drop(1) if entry[0] == :loudness

        :stop_music if stops && entry[0] == :stop_music
      end
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # --- fading the music out and back in ---

  # Said once, it walks the volume down over the frames it was given — the first of them still
  # at full, the last at nothing, the same reckoning `fade_out` makes for the screen — and holds
  # it there. The song goes on playing, silently, until something brings it back.
  def test_a_fade_out_walks_the_music_down_to_silence_and_holds_it_there
    program = held_note_game(named_once: true) { |pass| (pass == 10).then { fade_music_out frames: 5 } }
    heard = loudness_by_frame(program, 30, stops: true).reject { |frame, _| frame == 2 }

    assert_equal [[[1, 9]], [[1, 6]], [[1, 3]], [[1, 0]]], heard.values
    assert_equal (heard.keys.first...heard.keys.first + 4).to_a, heard.keys, "on four frames in a row"
  end

  # Brought in, the music comes up from nothing to full over the frames it was given — the song
  # playing now, or the one a game names in the same frame, which then starts silent.
  def test_a_fade_in_brings_the_music_up_from_silence
    program = held_note_game(named_once: true) { |pass| (pass == 10).then { fade_music_in frames: 5 } }
    heard = loudness_by_frame(program, 30).reject { |frame, _| frame == 2 }

    assert_equal [[[1, 0]], [[1, 3]], [[1, 6]], [[1, 9]], [[1, 12]]], heard.values
  end

  # A fade in said with no length comes up as fast as the last fade out went down.
  def test_a_fade_in_with_no_length_takes_as_long_as_the_fade_out_did
    program = held_note_game(named_once: true) do |pass|
      (pass == 5).then { fade_music_out frames: 3 }
      (pass == 15).then { fade_music_in }
    end
    heard = loudness_by_frame(program, 30).select { |frame, _| frame > 15 }

    assert_equal [[[1, 6]], [[1, 12]]], heard.values
  end

  # ...and on the console, where it can be heard: loud, then silent, then loud again.
  def test_the_console_fades_the_music_out_and_back_in
    program = held_note_game(named_once: true) do |pass|
      (pass == 10).then { fade_music_out frames: 10 }
      (pass == 40).then { fade_music_in }
    end
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSFADE"), frames: 70).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[4..9].min, :>, loud, "the song sounds (#{energy.inspect})"
    assert_operator energy[26..40].max, :<, loud, "then fades to nothing (#{energy.inspect})"
    assert_operator energy[58..].min, :>, loud, "and comes back (#{energy.inspect})"
  end

  # --- guardrails ---

  def warnings(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    RubyGBA::IR::Guardrails::Validator.new.run(b.program, autofix: false).warnings.map(&:check)
  end

  # A song faded out goes on playing silently, and so does every song after it — the game plays
  # on with no music and nothing says why.
  def test_music_faded_out_and_never_brought_back_is_caught
    found = warnings do
      screen :bitmap
      enable_sound
      song(:tune) { note :C4, :whole }
      game_loop do
        play_song :tune
        fade_music_out
      end
    end

    assert_includes found, :music_faded_out_never_in
  end

  def test_music_faded_out_and_brought_back_is_not_flagged
    found = warnings do
      screen :bitmap
      enable_sound
      song(:tune) { note :C4, :whole }
      pass = var :pass, 0
      game_loop do
        pass.add 1
        play_song :tune
        (pass == 10).then { fade_music_out }
        (pass == 90).then { fade_music_in }
      end
    end

    refute_includes found, :music_faded_out_never_in
  end

  # A fade in down the other branch of a test still brings it back.
  def test_music_brought_back_in_an_else_branch_is_not_flagged
    found = warnings do
      screen :bitmap
      enable_sound
      song(:tune) { note :C4, :whole }
      over = var :over, 0
      game_loop do
        play_song :tune
        (over == 1).then { fade_music_out }.else { fade_music_in }
      end
    end

    refute_includes found, :music_faded_out_never_in
  end

  # ...and turning it back up by hand brings it back just as well.
  def test_music_faded_out_and_turned_back_up_is_not_flagged
    found = warnings do
      screen :bitmap
      enable_sound
      song(:tune) { note :C4, :whole }
      pass = var :pass, 0
      game_loop do
        pass.add 1
        play_song :tune
        (pass == 10).then { fade_music_out }
        (pass == 90).then { music_volume 100 }
      end
    end

    refute_includes found, :music_faded_out_never_in
  end

  def test_a_game_that_never_fades_its_music_is_not_flagged
    found = warnings do
      screen :bitmap
      enable_sound
      song(:tune) { note :C4, :whole }
      game_loop { play_song :tune }
    end

    refute_includes found, :music_faded_out_never_in
  end

  # WHAT LETS A GAME WAIT FOR A FADE: `music_volume` with no number reads how loud the music is
  # now, 0 to 100. A song switched while nobody can hear it is a song switched without a jump.
  def test_the_music_volume_reads_back_how_loud_the_music_is_now
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      pass = var :pass, 0
      loud_at_start = var :loud_at_start, 0
      silent_at = var :silent_at, 0
      game_loop do
        pass.add 1
        (pass == 1).then { loud_at_start.set music_volume }
        (pass == 2).then { fade_music_out frames: 4 }
        ((music_volume == 0) & (silent_at == 0)).then { silent_at.set pass }
      end
    end
    b.emit_pending_functions
    run = Reference.new.run(b.program, frames: 20)

    assert_equal 100, run[:loud_at_start]
    assert_equal 5, run[:silent_at],
                 "a fade runs at the top of a pass, so it is down on passes 3 and 4 and silent by the " \
                 "body of the fifth"
  end

  # The note starts at its own volume, and a note ALREADY SOUNDING drops to half on the frame
  # after the game says so — the same one-frame step `play_song` takes, since the player that
  # sounds the notes reads what the game said at the start of the next frame.
  def test_half_the_music_volume_halves_a_note_already_sounding
    program = held_note_game { |pass| (pass == 5).then { music_volume 50 } }

    assert_equal({ 2 => [[1, 12]], 6 => [[1, 6]] }, loudness_by_frame(program, 10))
  end

  # ...and the console agrees about the volume the voice was set to.
  def test_the_console_sets_the_voice_to_the_same_volume
    program = held_note_game { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOL"), frames: 20)

    assert_equal 6, console.mem16(RubyGBA::Constants::REG_SOUND1CNT_H) >> 12
  end

  # ...and the speaker agrees: silence where the note is still being held. (On the console a
  # square voice takes its volume only as a note starts, so the player starts the held note
  # again. The emulator takes a new volume without that, so this cannot see the start itself —
  # see Audio#emit_scaled_note.)
  def test_no_music_volume_silences_a_note_the_console_is_already_holding
    program = held_note_game { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOL0"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end

  # --- a part that plays a recording ---

  # A recorded part sounds on a voice of the mixer, whose loudness runs 0..64 rather than 0..15 —
  # volume 12 is 51 of those — and the mixer takes a new one while a note plays, like the wave
  # voice. The log names the part by its place among the song's recorded parts.
  def test_half_the_music_volume_halves_a_recorded_note_already_sounding
    program = held_note_game(plays: :piano) { |pass| (pass == 5).then { music_volume 50 } }

    assert_equal({ 2 => [[[:mixer, 0], 51]], 6 => [[[:mixer, 0], 25]] }, loudness_by_frame(program, 10))
  end

  def test_the_console_sets_the_recorded_notes_voice_to_the_same_loudness
    program = held_note_game(plays: :piano) { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLR"), frames: 20)

    assert_equal [25], console.voices.map(&:volume)
  end

  def test_no_music_volume_silences_a_recorded_note_already_sounding
    program = held_note_game(plays: :piano) { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLR0"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end

  # --- a part on the noise voice ---

  # A drum part: a hit every second, at volume 12.
  def drum_game(&body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :drums do
        tempo 60
        voice(:kit, plays: :noise) do
          volume 12
          4.times { note :C4, :quarter }
        end
      end
      pass = var :pass, 0
      game_loop do
        pass.add 1
        play_song :drums
        instance_exec(pass, &body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  # A drum hit is struck, rings and fades by itself, so there is no held note to set again —
  # striking it again would be a second hit. The level reaches the next hit instead: the first at
  # its own volume, and the second, after the game halves the music, at half.
  def test_half_the_music_volume_reaches_the_next_drum_hit
    program = drum_game { |pass| (pass == 5).then { music_volume 50 } }

    assert_equal({ 2 => [[4, 12]], 62 => [[4, 6]] }, loudness_by_frame(program, 70))
  end

  def test_the_console_strikes_the_next_drum_hit_at_the_new_volume
    program = drum_game { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLN"), frames: 80)

    assert_equal 6, console.mem16(RubyGBA::Constants::REG_SOUND4CNT_L) >> 12
  end

  # --- a part on the wave voice ---

  # The wave voice holds its note at whatever volume it is given, while it plays — so a held
  # note simply gets the new one, and the voice it is on is channel 3.
  def test_half_the_music_volume_halves_a_note_on_the_wave_voice
    program = held_note_game(plays: :triangle) { |pass| (pass == 5).then { music_volume 50 } }

    assert_equal({ 2 => [[3, 12]], 6 => [[3, 6]] }, loudness_by_frame(program, 10))
  end

  # The wave voice has five volumes rather than sixteen, so the console sets the one nearest.
  def test_the_console_sets_the_wave_voice_to_the_nearest_of_its_volumes
    program = held_note_game(plays: :triangle) { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLW"), frames: 20)
    nearest = RubyGBA::Sound::Registers::WAVE_VOLUMES.fetch(RubyGBA::Sound::Registers.wave_level(6))

    assert_equal nearest, console.mem16(RubyGBA::Constants::REG_SOUND3CNT_H) & 0xE000
  end

  def test_no_music_volume_silences_a_note_the_wave_voice_is_holding
    program = held_note_game(plays: :triangle) { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLW0"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end
end
