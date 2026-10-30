# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "console/gba/vblank/dsl/test_sound_effects_on_the_advance"

# Sound effects that play recordings, on the Advance's cartridge: its wave RAM and its mixer's
# voices read back in the emulator and held to what the interpreter says. What the run's own
# player does with the same games is in test/console/gba/vblank/dsl/test_sound_effects_on_the_advance.rb.
class TestSoundEffectsOnTheAdvanceCartridge < Minitest::Test
  include SoundEffectsOnTheAdvanceGames

  # What a voice is set to that reads back: its volume, and a square voice's tone. Its pitch is
  # written with the bit that starts the note and does not read back.
  SETTING = 0xF0C0

  # What the block reads from the console after each of +frames+ frames.
  private def console_readings(program, frames:)
    require_emulator!
    rom = assemble_rom(program, name: "SFXVOICE")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sfx.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      readings = Array.new(frames) do
        probe.step(1)
        yield probe
      end
      probe.close
      readings
    end
  end

  # ...and from the console, reading wave RAM once a frame from the frame the voice first sounds.
  private def console_waveforms(program, frames:)
    readings = console_readings(program, frames: frames) do |probe|
      ram = (0...4).sum { |word| probe.read32(VBlank::Console::Hardware::REG_WAVE_RAM + (word * 4)) << (32 * word) }
      [probe.read32(VBlank::Console::Hardware::REG_SOUND3CNT_H) & SETTING, ram]
    end
    changes(readings.drop_while { |setting, _| setting.zero? }.map(&:last))
  end

  # --- the console's mixer ---

  # Whose each sounding voice is, +frames+ in, on each backend — the console run a little longer,
  # since it starts later. Every program here holds its voices steady for longer than that.
  private def owners_on_both(program, frames:)
    [game_player.run(program, frames: frames).sound_owners, console_voices(program, frames: frames).map(&:owner)]
  end

  private def console_voices(program, frames:) = console_run(program, frames: frames).voices

  private def console_run(program, frames:) = assert_emulator_loads_rom(assemble_rom(program, name: "SFXMIX"), frames: frames + 2)

  # The game's own `wave` puts its waveform in wave RAM too, so the song's next note puts the
  # song's back — in a game whose effects play the wave voice, whether or not one is playing. The
  # game's own sound is compared by its place in the order only: the game's code and the player
  # count their frames from different moments, so it lands a frame apart on the two backends.
  def test_the_console_loads_the_songs_waveform_again_after_the_games_own_wave
    program = games_own_wave_over_a_song
    want = interpreted_waveforms(program, frames: 30)
    got = console_waveforms(program, frames: 40).take_while { |frame, _| frame <= 26 }

    assert_equal want.map(&:last), got.map(&:last)
    assert_equal want.last, got.last, "the song's note puts the triangle back on the same frame"
  end

  def test_the_console_plays_an_effects_recording_on_a_voice_of_its_own
    assert_equal [[:"sfx.0", 0]], console_voices(recorded_effect_asked_for_once, frames: 8).map(&:owner)
  end

  # WHO GIVES WAY ON A FULL MIXER, on both backends: an effect over the song, a song over an
  # effect, and the game's own sound going first.
  def test_the_console_gives_a_voice_to_the_higher_rank_the_way_the_interpreter_does
    over = game([recorded_hit(68)], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    under = game([recorded_hit(68)], tune: chord(16, priority: 80)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    game_first = game([recorded_hit(68)], tune: chord(15)) do |sfx, pass|
      (pass == 1).then { @piano.play(:G4) }
      (pass == 10).then { sfx.play 0 }
    end

    [over, under, game_first].each do |program|
      interpreted, console = owners_on_both(program, frames: 20)
      assert_equal interpreted, console
    end
    assert_equal 1, console_run(under, frames: 20).sound_drops.dropped, "the console counts the note that did not play"
  end

  def test_the_console_decides_a_group_of_recorded_effects_the_way_the_interpreter_does
    recorded_pairs_and_owners.each do |program, moments|
      moments.each do |frames, owners|
        assert_equal owners, console_voices(program, frames: frames).map(&:owner), "#{frames} frames in"
      end
    end
  end

  # A fading note taken first, a song part that lost its voice having one again at its next note,
  # and a silent note taking none, on both backends.
  def test_the_console_takes_fading_notes_gives_voices_back_and_passes_over_silent_notes
    fading = game([recorded_hit(68)], tune: chord(16, length: 8, envelope: { release: 1.0 })) do |sfx, pass|
      (pass == 12).then { sfx.play 0 }
    end
    again = game([recorded_hit(68)], tune: chord(16, at: [0, 60])) { |sfx, pass| (pass == 10).then { sfx.play 0 } }
    quiet = Score.new(tempo: 150, priority: 68, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :D5, volume: 0),
    ])])
    silent = game([quiet], tune: chord(16)) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    [[fading, 18], [again, 30], [again, 72], [silent, 15], [silent, 27]].each do |program, frames|
      interpreted, console = owners_on_both(program, frames: frames)
      assert_equal interpreted, console, "#{frames} frames in"
    end
  end

  # An effect filling every voice: the song's note under it is not played, and its next one is.
  def test_the_console_plays_the_songs_next_note_once_an_effect_filling_the_mixer_ends
    [25, 45].each do |frames|
      interpreted, console = owners_on_both(effect_filling_the_mixer, frames: frames)
      assert_equal interpreted, console, "#{frames} frames in"
    end
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end.
  def test_the_console_keeps_and_lets_go_of_an_effects_voice_the_way_the_interpreter_does
    effect_voices_kept_and_let_go.each do |program, owners, frames|
      assert_equal owners, console_voices(program, frames: frames).map(&:owner), "#{frames} frames in"
    end
  end

  # An effect's voice plays at the effect's own volume while the music volume moves, and reads its
  # recording at its note's pitch.
  def test_the_console_plays_an_effects_recording_at_its_own_volume_and_pitch
    high = Score.new(tempo: 150, length: 200, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C5)])])
    program = game([high], tune: chord(1)) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 6).then { music_volume 50 }
    end
    voices = console_voices(program, frames: 12).to_h { |voice| [voice.owner, voice] }
    written = VBlank::IR::Tunes.mix_loudness(12) # a part's volume when it says none

    assert_equal written, voices.fetch([:"sfx.0", 0]).volume
    assert_equal VBlank::IR::Tunes.scaled_volume(written, 8), voices.fetch([:song, 0]).volume, "half the music volume"
    assert_in_delta 2.0, voices.fetch([:"sfx.0", 0]).step.fdiv(voices.fetch([:song, 0]).step), 0.01,
                    "read twice as fast, an octave above the song's C4"
  end
end
