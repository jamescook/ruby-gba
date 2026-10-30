# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/snake_buffered").to_s

# The buffered Snake example (examples/snake_buffered.rb): the demonstration that
# double buffering lets you write the naive "clear and repaint everything every
# frame" code and still play tear-free. Same game as examples/snake.rb, but drawn
# the simple way instead of incrementally — safe only because it's buffered.
#
# We prove it builds clean (which runs the guardrails and ROM-image checks). That it renders
# its title and playing board on the console, and keeps up, is read off the Advance's cartridge
# in test/lowering/gba/examples/test_snake_buffered_example_cartridge.rb.
class TestSnakeBufferedExample < Minitest::Test
  # VBlank.build runs the guardrails and validation, so a clean build IS the check.
  # This game used to warn that its frame goes over budget past about 419 cells. It no
  # longer does, and the warning was wrong rather than the check being broken: it was
  # priced before the build had decided anything, so it charged cartridge speed for a
  # frame the build actually keeps in the console's quick memory. The build keeps five of
  # this game's routines there AND the frame body, which takes the every-frame cost from
  # about 58 scanlines to about 40 — and a full 448-cell board then fits inside the 228 a
  # frame has.
  #
  # So the game builds clean, and the assertion is that nothing shouts about a budget it
  # does not exceed. What is NOT settled is whether a full board really fits on the
  # console: the one measurement on record here is of the four-cell snake the game opens
  # with. That is a question for a measured run rather than for either estimate.
  def test_the_example_builds_without_a_budget_warning
    err = StringIO.new
    rom = BufferedSnake.build_rom(err: err)

    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
    refute_match(/goes over budget/, err.string,
                 "priced with the build's own answers, a full board fits in a frame")
  end
end
