# frozen_string_literal: true

require "test_helper"

# Whether two sprites' drawn pixels touch (`overlaps?` without a hitbox) on a Super Nintendo is the
# interpreter's answer on every pass (SNES::CheckedRun). The pictures are rings with see-through
# middles, so their boxes overlap passes before their drawn pixels do, and one of them flips
# through its poses, so the answer is read from the picture it shows now.
class TestSNESCollision < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_touching_is_counted_by_drawn_pixels_like_the_interpreter
    run = checked(frames: 50) do
      screen :tiled
      image :ring, "." => :transparent, "o" => :yellow do
        "..oooo..\n.o....o.\no......o\no......o\no......o\no......o\n.o....o.\n..oooo..\n"
      end
      image(:dot, "." => :transparent, "o" => :red) { "........\n........\n...oo...\n...oo...\n" }
      image(:bar, "." => :transparent, "o" => :red) { "oooooooo\n........\n........\n........\n" }
      ring = sprite :ring, at: [100, 50]
      dart = sprite :dart, at: [60, 52], frames: %i[dot bar], rate: 3
      x = var :x, 60
      touches = var :touches, 0
      game_loop do
        x.add! 1
        dart.move_to x, 52
        ring.overlaps?(dart).then { touches.add! 1 }
      end
    end

    assert_operator run[:touches], :>, 0, "they touched"
    assert_operator run[:touches], :<, 40, "but not on every pass their boxes overlapped"
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames:, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
