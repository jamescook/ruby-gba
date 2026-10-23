# frozen_string_literal: true

require "test_helper"

# What every backend agrees on about a picture shown in blocks: how big a block can be,
# and that a program puts its blocks at one place in the stack.
class TestBlocks < Minitest::Test
  include RubyGBA::IR::Build

  Blocks = RubyGBA::IR::Backends::Blocks

  def test_a_size_past_either_end_stops_at_that_end
    assert_equal 1, Blocks.size(-3)
    assert_equal 1, Blocks.size(0)
    assert_equal 7, Blocks.size(7)
    assert_equal 16, Blocks.size(40)
  end

  # A program built by hand can say two places, which the DSL refuses as it is written.
  # No backend runs one: the interpreter could, and the console keeps "in blocks" as a
  # switch on each thing that is set once, so neither does.
  private def two_places
    program(screen(:tiled), layers(%i[world ui]),
            pixelate(size: int(4), under: :ui), pixelate(size: int(4)), halt)
  end

  def test_the_interpreter_refuses_a_program_with_two_places
    error = assert_raises(Reference::ProgramError) { game_player.run(two_places) }

    assert_match(/one place/, error.message)
    assert_match(/under :ui/, error.message)
  end

  def test_the_console_backend_refuses_a_program_with_two_places
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(two_places) }

    assert_match(/one place/, error.message)
    assert_match(/under :ui/, error.message)
  end
end
