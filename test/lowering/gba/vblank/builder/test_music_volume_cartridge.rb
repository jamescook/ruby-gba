# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/builder/test_music_volume"

# HOW LOUD THE MUSIC PLAYS, moved while it plays, on the Advance's own cartridge: the volume each
# of its voices is set to and what its speaker plays, read in the emulator. What every run plays
# is in test/all/vblank/builder/test_music_volume.rb, which keeps the games both files play in
# MusicVolumeGames.
class TestMusicVolumeCartridge < Minitest::Test
  include MusicVolumeGames

  # --- fading the music out and back in ---

  # THE TWO BACKENDS AGREE ON WHAT SOUNDED: over a whole fade out and back in, the volumes the
  # console's first square voice is set to, one after another, are the volumes the interpreter
  # logs, one after another — every step of the way, not only where it ends up.
  def test_both_backends_step_through_the_same_volumes
    program = held_note_game(named_once: true) do |pass|
      (pass == 10).then { fade_music_out frames: 9 }
      (pass == 30).then { fade_music_in frames: 9 }
    end
    interpreted = game_player.run(program, frames: 60).audio
                             .select { |entry| entry[0] == :loudness && entry[1] == 1 }.map(&:last)
    console = console_volumes(assemble_rom(program, name: "MUSSTEPS"), frames: 70)

    assert_equal interpreted.chunk_while { |a, b| a == b }.map(&:first), console
  end

  # The volume the console's first square voice was set to, frame by frame, with a run of the
  # same volume counted once.
  private def console_volumes(rom, frames:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "volumes.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      volumes = Array.new(frames) do
        probe.step(1)
        (probe.read32(VBlank::Console::Hardware::REG_SOUND1CNT_H) >> 12) & 0xF
      end
      probe.close
      volumes.chunk_while { |a, b| a == b }.map(&:first).drop_while(&:zero?)
    end
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

  # --- the music volume, on a note already sounding ---

  # ...and the console agrees about the volume the voice was set to.
  def test_the_console_sets_the_voice_to_the_same_volume
    program = held_note_game { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOL"), frames: 20)

    assert_equal 6, console.mem16(VBlank::Console::Hardware::REG_SOUND1CNT_H) >> 12
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

  def test_the_console_sets_the_recorded_notes_voice_to_the_same_loudness
    program = held_note_game(plays: :piano) { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLR"), frames: 20)

    assert_equal [205], console.voices.map(&:volume)
  end

  def test_no_music_volume_silences_a_recorded_note_already_sounding
    program = held_note_game(plays: :piano) { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLR0"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end

  def test_the_console_silences_a_recorded_note_without_a_shape_in_a_game_that_shapes
    program = held_note_game(plays: :piano, shaped_elsewhere: true) { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLRS"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end

  # --- a part on the noise voice ---

  def test_the_console_strikes_the_next_drum_hit_at_the_new_volume
    program = drum_game { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLN"), frames: 80)

    assert_equal 6, console.mem16(VBlank::Console::Hardware::REG_SOUND4CNT_L) >> 12
  end

  # --- a part on the wave voice ---

  # The wave voice has five volumes rather than sixteen, so the console sets the one nearest.
  def test_the_console_sets_the_wave_voice_to_the_nearest_of_its_volumes
    program = held_note_game(plays: :triangle) { |pass| (pass == 5).then { music_volume 50 } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLW"), frames: 20)
    nearest = VBlank::Audio::Sound::Registers::WAVE_VOLUMES.fetch(VBlank::Audio::Sound.wave_level(6))

    assert_equal nearest, console.mem16(VBlank::Console::Hardware::REG_SOUND3CNT_H) & 0xE000
  end

  def test_no_music_volume_silences_a_note_the_wave_voice_is_holding
    program = held_note_game(plays: :triangle) { |pass| (pass == 20).then { music_volume 0 } }
    energy = assert_emulator_loads_rom(assemble_rom(program, name: "MUSVOLW0"), frames: 40).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[5..15].min, :>, loud, "the note sounds at its own volume (#{energy.inspect})"
    assert_operator energy[28..].max, :<, loud, "and is silent once the music volume is 0 (#{energy.inspect})"
  end
end
