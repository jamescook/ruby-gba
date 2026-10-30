# frozen_string_literal: true

require "test_helper"

# The mixer: several samples sound at once instead of cutting each other off — background
# music plus overlapping sound effects, and (later) chords. `sample.play` adds a voice to
# the mix; `sample.stop` drops that sample's voices. The surface stays plain: play and
# stop, no voices or channels exposed.
#
# What every run plays is here. Voices sounding together, which only the Advance has, are in
# test/console/gba/vblank/ir/backends/reference/test_mixer_on_the_advance.rb, and the mix read
# straight off the Advance's cartridge in
# test/lowering/gba/vblank/ir/backends/reference/test_mixer_cartridge.rb.
class TestMixer < Minitest::Test
  # A COLOR PLAYS ONE RECORDING AT A TIME, so the interpreter, playing a game as a Color, sounds
  # the first and drops the rest, as it drops plays past the Advance's sixteen.
  def test_a_color_game_sounds_one_recording_at_a_time
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      first = sample :first, pcm: [25, -25] * 2000, rate: 8192
      second = sample :second, pcm: [25, -25] * 2000, rate: 8192
      first.play
      second.play
      game_loop { wait_vblank }
    end
    b.finalize_program
    i = Reference.new.run(b.program, frames: 3)

    assert_equal [:first], i.active_samples
    assert_equal [[:sample, :first], [:sample, :second]], i.audio.select { |event| event.first == :sample }
  end

  # THE VOICE TABLE DECODES WHATEVER MEMORY IT IS HANDED. The reader is passed in rather than
  # owned, so the decoding — which slot is sounding, which sample it is, whether it loops — is
  # checked here against a plain Hash, with no emulator anywhere. This is the one test that
  # knows the slot layout, which is right: it is the mixer's own.
  def test_the_voice_table_reads_the_sounding_slots_out_of_any_memory
    base = 0x0300_0000
    table = GBA::Mixer::VoiceTable.new(base: base, count: 3,
                                       clock: VBlank::Console::ADVANCE.sample_clock(8000),
                                       sample_addresses: { zap: 0x0800_1000, hum: 0x0800_2000 })
    at = ->(slot, field) { base + (slot * GBA::Mixer::SLOT_BYTES) + field }
    memory = Hash.new(0)
    memory[at[0, GBA::Mixer::SLOT_ACTIVE]] = 1 # slot 0 sounds :zap ...
    memory[at[0, GBA::Mixer::SLOT_SRC]] = 0x0800_1000
    memory[at[0, GBA::Mixer::SLOT_POS]] = 40
    memory[at[2, GBA::Mixer::SLOT_ACTIVE]] = 1 # ...slot 1 is idle, slot 2 loops :hum
    memory[at[2, GBA::Mixer::SLOT_SRC]] = 0x0800_2000
    memory[at[2, GBA::Mixer::SLOT_LOOP]] = 1

    voices = table.read { |address| memory[address] }

    assert_equal %i[zap hum], voices.map(&:sample), "the idle slot between them is skipped"
    assert_equal 40, voices.first.position
    assert voices.last.loop, "the looping flag reads back as true"
    refute voices.first.loop
  end

  # --- level control ---

  def test_a_bad_volume_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        s = sample :s, pcm: [0, 1], rate: 8000
        s.play(volume: :loud)
      end
    end
    assert_match(/level/i, err.message)
  end
end
