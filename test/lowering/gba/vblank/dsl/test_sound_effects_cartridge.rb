# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_sound_effects"

# Sound effects over a song on the Advance's cartridge: the sound hardware's registers read back
# in the emulator, frame by frame, held to what the interpreter says each voice was set to, and
# what the profile says the effects cost. What every run's player does with the same games is in
# test/all/vblank/dsl/test_sound_effects.rb.
class TestSoundEffectsCartridge < Minitest::Test
  include SoundEffectsGames

  # What a voice is set to that reads back: its volume, and a square voice's tone. Its pitch is
  # written with the bit that starts the note and does not read back, so the effect's part is
  # told from the song's by being quieter and thinner.
  SETTING = 0xF0C0

  SQUARE_1 = VBlank::Console::Hardware::REG_SOUND1CNT_H
  NOISE = VBlank::Console::Hardware::REG_SOUND4CNT_L

  REGISTERS = { 1 => SQUARE_1, 2 => VBlank::Console::Hardware::REG_SOUND2CNT_L, 3 => VBlank::Console::Hardware::REG_SOUND3CNT_H,
                4 => NOISE }.freeze

  # How a voice was set on the console: [frames since it first sounded, setting] for each change.
  private def console_changes(program, register, frames:)
    changes(console_readings(program, frames: frames) { |probe| probe.read32(register) & SETTING })
  end

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

  # The two backends agree about when a voice changed and what it changed to, from the first sound
  # the interpreter heard to its last — the console runs on a little, since it starts later.
  private def assert_backends_share_the_voice(program, tones, channel: 1)
    want = interpreted_changes(program, channel, tones, frames: 60)
    got = console_changes(program, REGISTERS.fetch(channel), frames: 75).take_while { |frame, _| frame <= 56 }

    assert_equal want.take_while { |frame, _| frame <= 56 }, got, "the voice numbered #{channel}"
  end

  private def square_setting(tone, volume) = setting(tone, volume)

  # ...and from the console, reading wave RAM once a frame from the frame the voice first sounds.
  private def console_waveforms(program, frames:)
    readings = console_readings(program, frames: frames) do |probe|
      ram = (0...4).sum { |word| probe.read32(VBlank::Console::Hardware::REG_WAVE_RAM + (word * 4)) << (32 * word) }
      [probe.read32(REGISTERS.fetch(3)) & SETTING, ram]
    end
    changes(readings.drop_while { |setting, _| setting.zero? }.map(&:last))
  end

  # A note at volume 0 sounds nothing, so it lets the voice go the way a rest does: the song's note
  # on frame 22 is heard, on the console too.
  def test_a_silent_note_lets_the_voice_go
    assert_includes console_changes(silent_note_over_a_song, SQUARE_1, frames: 40), [20, square_setting(:half, 12)],
                    "the console plays the song's note 20 frames after its first"
  end

  # The wave voice has five volumes, and the nearest to 1 of 15 is none: that note is silent, so it
  # lets the voice go, on the console as on the interpreter.
  def test_a_note_too_quiet_for_the_wave_voice_lets_it_go
    assert_backends_share_the_voice(too_quiet_for_the_wave_voice, WAVE_TONES, channel: 3)
  end

  # THE TWO BACKENDS AGREE ABOUT WHO SOUNDED ON A SHARED VOICE, and when, one way round and the
  # other: the effect taking the first square voice and the song coming back after it, and the
  # song keeping it against an effect it outranks.
  def test_the_console_shares_a_square_voice_the_way_the_interpreter_does
    assert_backends_share_the_voice(song_and_effect(song_priority: 0, effect_priority: 68), SONG_TONES)
    assert_backends_share_the_voice(song_and_effect(song_priority: 80, effect_priority: 68), SONG_TONES)
    assert_backends_share_the_voice(song_and_effect(song_priority: 0, effect_priority: 0), SONG_TONES) # a tie
  end

  # ...and keeps a voice for a song's note that swells in from volume 0: the effect it outranks never
  # writes the voice.
  def test_the_console_keeps_a_voice_for_a_note_swelling_from_nothing
    written = console_changes(swelling_song_and_effect, SQUARE_1, frames: 50).map(&:last)

    refute_includes written, SONG_SETTING[:"sfx.0"], "the effect's note on the song's voice"
  end

  def test_the_console_shares_the_noise_voice_the_way_the_interpreter_does
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :noise)

    assert_backends_share_the_voice(program, NOISE_TONES, channel: 4)
  end

  def test_the_console_shares_the_wave_voice_the_way_the_interpreter_does
    program = song_and_effect(song_priority: 0, effect_priority: 68, plays: :triangle, effect_plays: :sawtooth)

    assert_backends_share_the_voice(program, WAVE_TONES, channel: 3)
  end

  # THE WAVEFORM ON THE CONSOLE. The wave voice loops whatever waveform is in wave RAM, and there
  # is room there for one, so an effect's note has to put its own there — and the song's note after
  # it has to put the song's back. (See #two_tunes_on_the_wave_voice_under_an_effect for the game.)
  def test_the_console_loads_the_waveform_of_each_note
    assert_equal [[0, waveform(:triangle)], [11, waveform(:sawtooth)], [25, waveform(:sine)]],
                 console_waveforms(two_tunes_on_the_wave_voice_under_an_effect, frames: 50)
                   .take_while { |frame, _| frame <= 36 }
  end

  # THE HIT'S SHAPE: an effect on a square voice and the noise voice at once, over a song on both.
  def test_the_console_shares_a_square_voice_and_the_noise_voice_at_once
    notes = [Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4)]
    tune = Score.new(tempo: 150, parts: [Part.new(notes: notes), Part.new(plays: :noise, notes: notes)])
    hit_notes = [Note.new(at: 0, key: :C5), Note.new(at: 5, key: :D5)]
    hit = Score.new(tempo: 150, priority: 68, parts: [Part.new(volume: 9, duty: :quarter, notes: hit_notes),
                                                      Part.new(plays: :noise, volume: 9, notes: hit_notes)])
    program = game([hit], tune: tune) { |sfx, pass| (pass == 10).then { sfx.play 0 } }

    assert_backends_share_the_voice(program, SONG_TONES)
    assert_backends_share_the_voice(program, NOISE_TONES, channel: 4)
  end

  # A SONG RANKED BETWEEN TWO EFFECTS, so the player walks the effects above it before the song's
  # parts and the one below it after them. The higher one takes the first square voice from the
  # song; the lower one, asked for while that is sounding, is silent there and heard on the second
  # square voice, which nobody else wants.
  def test_the_console_plays_effects_on_both_sides_of_the_songs_rank
    program = effects_on_both_sides_of_the_songs_rank

    assert_backends_share_the_voice(program, BOTH_SIDES_TONES)
    assert_backends_share_the_voice(program, BOTH_SIDES_TONES, channel: 2)
  end

  # With no song at all, and asked for twice so it starts again.
  def test_the_console_plays_an_effect_once_and_starts_it_again
    assert_backends_share_the_voice(effect_asked_for_twice, { "sfx.0": :half })
  end

  # By a number the game works out, turned into its place in the table: the quieter of the two,
  # and then nothing for a number naming no effect.
  def test_the_console_plays_the_effect_a_number_names
    assert_backends_share_the_voice(effect_picked_by_a_number, PICKED_TONES)
  end

  # Two effects on one voice, of one priority, asked for on one frame: the one declared first.
  def test_the_console_breaks_a_tie_between_effects_the_way_the_interpreter_does
    assert_backends_share_the_voice(two_effects_tied_on_one_voice, PICKED_TONES)
  end

  # The song starting over while an effect sounds leaves the effect's voice alone on the console
  # too.
  def test_the_console_keeps_an_effects_voice_when_the_song_starts_over
    program = long_note_under_an_effect { |pass| (pass == 15).then { stop_music } }

    assert_backends_share_the_voice(program, SONG_TONES)
  end

  # ...and a music volume moving while an effect sounds does not start the song's lost note again
  # over it, then or after the effect ends.
  def test_the_console_keeps_an_effects_voice_when_the_music_volume_moves
    program = long_note_under_an_effect { |pass| (pass == 20).then { music_volume 50 } }

    assert_backends_share_the_voice(program, SONG_TONES)
  end

  # ...and the same on the wave voice, whose held note takes a new volume without starting again.
  def test_the_console_keeps_an_effects_wave_voice_when_the_music_volume_moves
    program = long_note_under_an_effect(plays: :triangle, effect_plays: :sawtooth) do |pass|
      (pass == 20).then { music_volume 50 }
    end

    assert_backends_share_the_voice(program, WAVE_TONES, channel: 3)
  end

  # A GROUP ON THE CONSOLE: the square voice the cry plays and the noise voice the hurt plays are
  # set the same way the interpreter sets them.
  private def assert_backends_share_both_voices(program)
    assert_backends_share_the_voice(program, GROUP_TONES)
    assert_backends_share_the_voice(program, GROUP_TONES, channel: 4)
  end

  def test_the_console_cuts_an_effect_off_for_a_higher_one_of_its_group
    assert_backends_share_both_voices(cry_then_hurt(cry_priority: 64, hurt_priority: 72))
  end

  def test_the_console_does_not_play_a_lower_one_of_a_group
    assert_backends_share_both_voices(cry_then_hurt(cry_priority: 72, hurt_priority: 64))
  end

  def test_the_console_cuts_an_effect_off_on_a_tie_in_its_group
    assert_backends_share_both_voices(cry_then_hurt(cry_priority: 64, hurt_priority: 64))
  end

  def test_the_console_plays_effects_of_two_groups_together
    two_groups = game([cry(72, group: :voice), hurt(64, group: :sword)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 1 }
    end

    assert_backends_share_both_voices(two_groups)
  end

  # Asked for again, it goes quiet until its first note — which, in this one, comes five frames in.
  def test_the_console_stops_an_effect_of_a_group_asked_for_again
    assert_backends_share_the_voice(late_effect_of_a_group_asked_for_twice, GROUP_TONES)
  end

  # Two of a group asked for on one pass, in either order; and one asked for again on the pass a
  # lower one is, sounding or not.
  def test_the_console_decides_several_asks_on_one_pass_the_way_the_interpreter_does
    together = [[1, 0], [0, 1]].map do |order|
      game([cry(64), hurt(72)]) { |sfx, pass| (pass == 3).then { order.each { |which| sfx.play which } } }
    end
    again_and_lower = game([cry(72), hurt(64)]) do |sfx, pass|
      (pass == 3).then { sfx.play 0 }
      (pass == 8).then { sfx.play 0; sfx.play 1 }
    end
    twice_and_lower = game([cry(72), hurt(64)]) { |sfx, pass| (pass == 3).then { sfx.play 0; sfx.play 0; sfx.play 1 } }

    [*together, again_and_lower, twice_and_lower].each { |program| assert_backends_share_both_voices(program) }
  end

  # A number the game works out, naming an effect with no group in a list that has groups in it,
  # plays it alongside the one sounding.
  def test_the_console_plays_an_effect_with_no_group_from_a_list_with_groups
    assert_backends_share_both_voices(ungrouped_effect_from_a_list_with_groups)
  end

  # --- what it costs ---

  # THE PROFILE COUNTS IT, inside the routine that answers the display, which is where the player
  # runs: a game whose effects are sounding spends more there than the same game with them silent.
  def test_the_profile_counts_what_the_sound_effects_cost
    interrupt_samples = lambda do |playing|
      effects = Array.new(8) { |n| every_ten_ticks(:C5, :E5, :G5, priority: n) }
      rom = VBlank.build("SFXCOST", console: :gba, code: "ZSFX", maker: "01", out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        enable_sound
        sfx = sound_effects :sfx, effects
        game_loop { effects.size.times { |n| sfx.play n } if playing }
      end
      VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).lines.find { |line| line.name == :__interrupt }.samples
    end

    assert_operator interrupt_samples.call(true), :>, interrupt_samples.call(false)
  end
end
