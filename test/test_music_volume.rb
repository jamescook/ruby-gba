# frozen_string_literal: true

require "test_helper"

# HOW LOUD THE MUSIC PLAYS, moved while it plays.
#
# A part's volume is written into the song, and until now nothing could change it once the song
# was built. `music_volume` scales every part of whatever song is playing — a settings screen's
# music slider, and the level `fade_music_out` walks down to silence.
class TestMusicVolume < Minitest::Test
  # A song holding one long note at volume 12 — on the first square voice, or on whichever voice
  # +plays+ names — and a game that runs +body+ on each pass with the pass number.
  def held_note_game(plays: nil, &body)
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
        play_song :hold
        instance_exec(pass, &body)
      end
    end
    b.emit_pending_functions
    b.program
  end

  # How loud each square voice was set, on the frames it was set, from the interpreter:
  # { frame => [[channel, volume 0..15], ...] }.
  def loudness_by_frame(program, frames)
    i = Reference.new
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).select { |entry| entry[0] == :loudness }.map { |entry| entry.drop(1) }
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
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
