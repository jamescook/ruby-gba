# frozen_string_literal: true

require "test_helper"

# A painted screen on a Game Boy Color is 360 tiles the runtime keeps in work memory and sends to
# the console between passes (GBC::Runtime::Paint). Each test is a small painted program played as
# a Color cartridge and checked against the interpreter after every pass (GBC::CheckedRun), so a
# picture that differs anywhere fails it, besides what it asserts.
class TestGBCPaint < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  # A clear in a new colour points all 360 cells at that colour, and a tile painted after it in the
  # same pass is sent as its own picture as well: the pass's list of what to send must hold both.
  def test_a_rectangle_painted_after_a_clear_in_a_new_colour_shows
    run = checked(frames: 2) do
      screen :bitmap
      clear_screen :blue
      draw_rect_at 100, 40, 2, 2, :red
      halt
    end

    assert_equal RubyGBA::Graphics::Color.resolve(:red), run.screen.pixel(100, 40)
    assert_equal RubyGBA::Graphics::Color.resolve(:blue), run.screen.pixel(0, 0)
  end

  private

  def checked(frames:, &game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    GBC::CheckedRun.new.run(program, frames: frames)
  end
end
