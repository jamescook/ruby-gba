# frozen_string_literal: true

require "test_helper"

# The test of test_keep_showing.rb about a tear-free screen's two pages, which only the Advance
# keeps: a Game Boy Color shows a painted picture whole, so one page is all it has, and a single
# paint is on every frame there.
class TestKeepShowingOnTheAdvance < Minitest::Test
  # Written by hand without the verb, a single paint lands on one page only — the
  # bug the verb exists to remove. This is the control: same program, same frames,
  # one paint instead of two, and the picture is there on one parity and gone on
  # the other.
  def test_without_it_a_single_paint_reaches_only_one_page
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      clear_screen :black
      n = var :n, 0
      game_loop do
        n.add! 1
        (n == 2).then { draw_rect_at 10, 10, 20, 20, :red }
      end
    end
    b.finalize_program

    red = Color.resolve(:red)
    on_page = [6, 7].map { |f| game_player.run(b.program, frames: f).screen.pixel(15, 15) == red }
    assert_equal 1, on_page.count(true),
                 "a single paint should show on exactly one of the two pages, got #{on_page.inspect}"
  end
end
