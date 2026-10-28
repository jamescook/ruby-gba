# frozen_string_literal: true

require "test_helper"

# WHAT A SUPER NINTENDO GAME SOUNDS LIKE, measured in the sound bsnes plays rather than in the
# registers the game wrote. The checked run holds the S-DSP's registers to the interpreter's sound
# log at the end of every pass, which cannot see what happens between two passes: the order of
# writes inside one, a fade's shape, a note's first moment. These listen. The Advance's mix and the
# S-DSP's are not the same machine, so they compare a sound's shape — when it starts, how long it
# lasts, which part is louder — never its samples.
class TestSNESHeard < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build

  # The frames a held note is measured over once it has started: past its first.
  STEADY = 1..8

  # A program that turns the sound on, does +body+, and waits.
  private def sounding(*body)
    program = Build.program(Build.enable_sound, *body, Build.loop_(Build.wait_vblank))
    program.console = :snes
    program
  end

  # The loudest sample of each frame +program+ played, checked, from the first frame that sounds.
  private def loudest_from_onset(program, frames:)
    SNES::CheckedRun.new.run(program, frames: frames).loudest_each_frame.drop_while(&:zero?)
  end

  # A tune of a note for 20 frames, a rest for 20, and the note again: a rest lets the voice go,
  # and the S-DSP's release takes the envelope down by 8 of its 2047 every sample (fullsnes, "ADSR/Gain
  # Envelope"), 256 samples, a part of one frame. So the output falls silent for the rest, all but
  # the frame the release falls in, and sounds again when the note comes back.
  def test_a_rest_is_silent_in_the_sound_played
    tune = Build.song(:tune, events: [[0, 440], [20, 0], [40, 440]], total_frames: 60)
    loudest = loudest_from_onset(sounding(tune, Build.play_song(:tune)), frames: 70)
    runs = loudest.take(60).chunk_while { |a, b| a.zero? == b.zero? }.map { |run| [run.first.zero?, run.size] }

    assert_equal [false, true, false], runs.map(&:first), "a note, a silence, a note: #{runs.inspect}"
    assert_includes 19..20, runs[1].last, "the rest's frames, less the one its release falls in"
  end

  # The Advance takes a beep down a volume step every 5 64ths of a second at :slow, so one at
  # volume 15 is gone in 15 * 5 / 64 of a second, 70 frames, and one at volume 5 in 23. The DSP
  # fades at the nearest of its own rates, which lie up to a third apart, so each is heard for
  # about as long — and the quiet one a third as long as the loud one, as on the Advance.
  def test_a_beep_fades_out_in_about_the_advances_time
    loud, quiet = [15, 5].map do |volume|
      sound = Build.define_sound(:ping, frequency: 440, decay: :slow, volume: volume)
      loudest_from_onset(sounding(sound, Build.beep(:ping)), frames: 100).take_while(&:positive?).size
    end

    assert_in_delta 70, loud, 70 * 0.2, "volume 15 at :slow"
    assert_in_delta 23, quiet, 23 * 0.2, "volume 5 at :slow"
  end

  # A wave note under music_volume 50 plays the recording of its waveform at :half, half the swing
  # of the note's own at :full. The wave voice changes recording only where the one it is reading
  # comes round (fullsnes, "SRCN"), so a note keyed on before its recording was written would play
  # once round at :full first, and its first frame would be twice as loud as the rest. Heard, the
  # first frame is about as loud as the frames after it — a little over, as the voice's first
  # samples are read with nothing before them to smooth them against — and those are about half
  # as loud as the note at full volume.
  def test_a_wave_note_under_a_music_volume_starts_quiet
    full, half = [100, 50].map do |level|
      game = VBlank.game("WAVEHEARD", consoles: %i[gba snes]) do
        enable_sound
        song(:tune) { voice(:hum, plays: :triangle) { volume 15; note :A3, :whole } }
        music_volume level
        game_loop { play_song :tune }
      end
      loudest_from_onset(game.program(console: :snes), frames: 12)
    end
    steady = half[STEADY].max

    assert_operator half.first, :<=, steady * 1.1, "the note's first frame against the frames after it"
    assert_in_delta 0.5, steady.fdiv(full[STEADY].max), 0.1, "half the note's loudness at full"
  end
end
