# frozen_string_literal: true

require "test_helper"

# `list ..., full_of:` with a list of bytes longer than a Game Boy Color's work memory: every
# width, a value below nothing, and an odd count of bytes so the fill has ends that are not whole
# words; the item after the list is never written. The same readings off the Advance's cartridge,
# in the emulator, are in test/lowering/gba/vblank/test_list_full_of_on_the_advance_cartridge.rb,
# which plays the game kept here in ListFullOfOnTheAdvanceGames.
module ListFullOfOnTheAdvanceGames
  READINGS = %i[bytes_held byte_first byte_last half_last word_first word_last after_first ring_first ring_last].freeze

  # What every reading holds once the game has run.
  EXPECTED = [4099, -1, -1, 300, -70_000, -70_000, 9, 4, 6].freeze

  WIDTHS = Ractor.make_shareable(proc do
    bytes = list :bytes, capacity: 4099, width: :byte, full_of: -1, fast: false
    halves = list :halves, capacity: 3, width: :half, full_of: 300
    words = list :words, capacity: 2, full_of: -70_000
    after = list :after, capacity: 1
    after.push 9
    # A list the game shifts is a ring on the console, its slots rounded up past the capacity.
    ring = list :ring, capacity: 3, full_of: 4
    ring.shift
    ring.push 6
    readings = READINGS.to_h { |name| [name, var(name, 0)] }
    game_loop do
      readings[:bytes_held].set! bytes.length
      readings[:byte_first].set! bytes[0]
      readings[:byte_last].set! bytes[4098]
      readings[:half_last].set! halves[2]
      readings[:word_first].set! words[0]
      readings[:word_last].set! words[1]
      readings[:after_first].set! after[0]
      readings[:ring_first].set! ring[0]
      readings[:ring_last].set! ring[2]
    end
  end)
end

class TestListFullOfOnTheAdvance < Minitest::Test
  include ListFullOfOnTheAdvanceGames

  def test_the_console_starts_every_width_full_as_the_interpreter_does
    builder = Builder.new
    builder.instance_eval(&WIDTHS)
    builder.finalize_program
    run = game_player.run(builder.program, frames: 2)

    assert_equal EXPECTED, READINGS.map { |name| run[name] }
  end
end
