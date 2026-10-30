# frozen_string_literal: true

require "test_helper"

# `late:` on the tear-free screen says WHEN a late page is shown, never what is on it — so on
# every lowering the game draws the same picture with it as without it. When it is shown is the
# console's to measure (see test/lowering/gba/vblank/ir/backends/gba/test_late_pages.rb).
class TestScreenLate < Minitest::Test
  private def program(late, pace: 60)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, late: late, pace: late == :wait ? 60 : pace
      game_loop do
        clear_screen :gray
        draw_rect_at 10, 10, 20, 30, :red
      end
    end
    b.finalize_program
    b.program
  end

  def test_every_setting_draws_the_same_picture
    pictures = [:wait, :show_now, 40].map { |late| game_player.run(program(late), frames: 3).screen.to_a }
    pictures << game_player.run(program(:show_now, pace: 30), frames: 3).screen.to_a

    assert_equal 1, pictures.uniq.size
    assert_equal Color.resolve(:red), game_player.run(program(:show_now), frames: 3).screen.pixel(15, 15)
  end

  def test_late_on_a_screen_that_is_not_tear_free_says_why
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap, late: :show_now }
    end

    assert_match(/tear_free: true/, err.message)
  end

  def test_a_setting_late_does_not_know_names_the_ones_it_does
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap, tear_free: true, late: :soon }
    end

    assert_match(/:show_now/, err.message)
    assert_match(/:wait/, err.message)
  end

  def test_a_pace_the_screen_cannot_keep_names_the_ones_it_can
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap, tear_free: true, late: :show_now, pace: 45 }
    end

    assert_match(/60, 30, 20 or 15/, err.message)
  end

  def test_a_pace_on_a_screen_that_waits_says_why
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap, tear_free: true, pace: 30 }
    end

    assert_match(/late:/, err.message)
  end

  def test_a_row_past_the_screen_says_which_rows_there_are
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { screen :bitmap, tear_free: true, late: 200 }
    end

    assert_match(/159/, err.message)
  end

  # The rows are the screen's the game is built for: a Game Boy Color's has 144, so row 150 is
  # past its bottom there, and a row the Advance's screen has.
  def test_the_rows_are_the_screen_of_the_console_the_game_is_built_for
    color = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    err = assert_raises(ArgumentError) { color.instance_eval { screen :bitmap, tear_free: true, late: 150 } }
    assert_match(/from 0 to 143/, err.message)

    advance = Builder.new
    advance.instance_eval { screen :bitmap, tear_free: true, late: 150 }
    assert_equal 150, advance.program.walk.find { |node| node.kind == :screen }.late
  end
end
