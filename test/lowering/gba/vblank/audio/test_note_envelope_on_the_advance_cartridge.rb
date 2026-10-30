# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/audio/test_note_envelope_on_the_advance"

# THE VOICES A FALLING NOTE HOLDS ON THE ADVANCE'S CARTRIDGE, read in the emulator. What every run
# of an Advance game has sounding is in
# test/console/gba/vblank/audio/test_note_envelope_on_the_advance.rb.
class TestNoteEnvelopeOnTheAdvanceCartridge < Minitest::Test
  include EmulatorSupport
  include NoteEnvelopeAdvanceGames

  # What the Advance's cartridge has sounding +frames+ in, and what it could not play, given two
  # frames more to get there.
  private def cartridge_voices(program, frames:)
    console = assert_emulator_loads_rom(assemble_rom(program, name: "TAILS"), frames: frames + 2)
    [console.sounding, console.sound_drops]
  end

  def test_a_parts_next_note_leaves_the_last_falling_on_its_own_voice
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, instrument: :low),
             VBlank::Audio::Score::Note.new(at: 10, key: :C4, instrument: :high)]
    console, = cartridge_voices(voices_game(notes), frames: 14)

    assert_equal %i[low high], console, "the first note falls away on its voice while the second sounds on another"
  end

  def test_a_game_sound_takes_a_falling_notes_voice_rather_than_being_dropped
    notes = [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 4)]
    program = voices_game(notes, burst: 10)
    console = cartridge_voices(program, frames: 14)

    clips = (0...VOICES).map { |n| :"s#{n}" }

    assert_equal [clips.last] + clips[0...-1], console.first,
                 "every voice is the game's: the last sound took the first voice, which the falling note gave up"
    assert_equal 0, console.last.dropped
    assert_equal game_player.run(program, frames: 14).sound_drops, console.last,
                 "the cartridge counts what it dropped the way the interpreter does"
  end
end
