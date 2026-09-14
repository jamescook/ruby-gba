# frozen_string_literal: true

require "test_helper"

# HOW LOUD THE MUSIC PLAYS, moved while it plays.
#
# A part's volume is written into the song, and until now nothing could change it once the song
# was built. `music_volume` scales every part of whatever song is playing — a settings screen's
# music slider, and the level `fade_music_out` walks down to silence.
class TestMusicVolume < Minitest::Test
  # A song holding one long note at volume 12 on the first square voice, and a game that runs
  # +body+ on each pass with the pass number.
  def held_note_game(&body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :hold do
        tempo 60
        volume 12
        note :C4, :whole
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
end
