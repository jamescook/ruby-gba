# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The menu over the window a game is played in (WindowMenu says what it holds): a bar
# of headings, the open heading's lines under it, worked with the arrows and Enter. These play it
# with no window at all, and read what it would have a window draw.
class TestMenu < Minitest::Test
  Menu = VBlank::Live::Menu
  WindowMenu = VBlank::Live::WindowMenu

  def test_a_menu_starts_closed_with_the_desktop_builds_settings
    menu = Menu.new

    refute menu.open?
    assert_equal({ fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false, frame_rate: true },
                 menu.settings.to_h)
  end

  # Opened, it shows the first heading's lines with none of them chosen, so the next key a player
  # presses moves somewhere rather than changing something.
  def test_a_menu_opens_on_the_bar_with_no_line_chosen
    menu = opened

    assert_equal "Game", menu.open_heading
    assert_nil menu.chosen_line
  end

  # Left and right on the bar go from heading to heading, round at either end, and choose no line
  # under any of them: passing the window's size on the way to the sound leaves it as it was.
  def test_left_and_right_on_the_bar_move_between_headings_and_change_nothing
    menu = opened
    menu.press(:right)
    menu.press(:right)
    assert_equal "Sound", menu.open_heading
    assert_nil menu.chosen_line

    menu.press(:right)
    assert_equal "Game", menu.open_heading
    menu.press(:left)
    assert_equal "Sound", menu.open_heading
    assert_equal WindowMenu::STARTING, menu.settings
  end

  def test_down_or_enter_goes_into_the_lines_and_up_from_the_first_comes_back
    menu = opened
    menu.press(:down)
    assert_equal "Resume", menu.chosen_line

    menu.press(:up)
    assert_nil menu.chosen_line
    menu.press(:enter)
    assert_equal "Resume", menu.chosen_line
  end

  # Down past the last line goes round to the first.
  def test_down_goes_round_the_lines
    menu = opened
    4.times { menu.press(:down) }

    assert_equal "Resume", menu.chosen_line
  end

  # On a slider, left and right change its number a step at a time, never past what it can be.
  def test_left_and_right_on_a_slider_change_it
    menu = opened
    2.times { menu.press(:down) }
    6.times { menu.press(:right) }
    assert_equal 8, menu.settings.fast_forward_speed

    menu.press(:right)
    menu.press(:right)
    menu.press(:right)
    menu.press(:right)
    menu.press(:left)
    menu.press(:left)
    assert_equal 6, menu.settings.fast_forward_speed
  end

  def test_volume_goes_in_tens
    menu = opened
    2.times { menu.press(:right) }
    menu.press(:down)
    3.times { menu.press(:left) }

    assert_equal 70, menu.settings.volume
  end

  # On a line that is not a slider, left and right go on to the next heading, back on the bar.
  def test_left_and_right_on_another_line_move_to_the_next_heading
    menu = opened
    menu.press(:down)
    menu.press(:right)

    assert_equal "Window", menu.open_heading
    assert_nil menu.chosen_line
  end

  def test_enter_switches_a_check_on_and_off
    menu = opened
    menu.press(:right)
    2.times { menu.press(:down) }
    menu.press(:enter)
    assert menu.settings.fullscreen

    menu.press(:enter)
    refute menu.settings.fullscreen
  end

  def test_enter_on_resume_closes_the_menu_and_on_quit_asks_to_stop
    menu = opened
    menu.press(:down)
    menu.press(:enter)
    refute menu.open?

    menu.toggle
    3.times { menu.press(:down) }
    menu.press(:enter)
    assert menu.quit?
  end

  # The gamepad's B closes the menu from anywhere in it.
  def test_close_closes_the_menu
    menu = opened
    menu.press(:down)
    menu.press(:close)

    refute menu.open?
  end

  # A menu opened again starts on the bar, on the first heading.
  def test_a_menu_opens_again_on_the_first_heading
    menu = opened
    menu.press(:right)
    menu.press(:down)
    menu.toggle
    menu.toggle

    assert_equal "Game", menu.open_heading
    assert_nil menu.chosen_line
  end

  # The window is made no bigger than the frontend says fits on the screen.
  def test_the_window_size_goes_no_higher_than_the_frontend_allows
    menu = Menu.new(scales: 1..4)
    menu.toggle
    menu.press(:right)
    menu.press(:down)
    5.times { menu.press(:right) }

    assert_equal 4, menu.settings.scale
  end

  # --- what it has a window draw ---

  def test_the_bar_shows_every_heading_and_the_open_headings_lines
    words = drawn_words(opened)

    assert_equal %w[Game Window Sound Resume F1 Fast\ forward 4x Quit Esc], words.map(&:text)
  end

  def test_a_closed_menu_draws_nothing_but_what_the_window_is_doing
    assert_empty Menu.new.drawing(width: 720, density: 1)

    status = Menu.new.drawing(width: 720, density: 1, held: true, fast_forward: nil, frame_rate: 60)
    assert_equal ["60 fps", "PAUSED"], status.grep(WindowMenu::Words).map(&:text)
  end

  def test_fast_forward_is_said_in_the_corner_with_its_speed
    status = Menu.new.drawing(width: 720, density: 1, fast_forward: 4)

    assert_equal ["FAST FORWARD 4x"], status.grep(WindowMenu::Words).map(&:text)
  end

  # The size line says what the window would be, and a check mark is drawn only for a check that
  # is on.
  def test_the_window_heading_says_the_size_and_marks_what_is_on
    menu = opened(settings: WindowMenu::STARTING.with(frame_rate: true))
    menu.press(:right)

    assert_equal ["Size", "3x  (720 × 480)", "Fullscreen", "Show frame rate", "✓"],
                 drawn_words(menu).map(&:text).drop(3)
  end

  # The chosen line has the chosen colour behind it, across the box.
  def test_the_chosen_line_has_a_bar_behind_it
    menu = opened
    menu.press(:down)
    resume = drawn_words(menu).find { |words| words.text == "Resume" }
    behind = menu.drawing(width: 720, density: 1).grep(WindowMenu::Box)
                 .select { |box| box.color == WindowMenu::COLORS[:chosen] }

    assert_equal 1, behind.size
    assert_operator behind.first.y, :<=, resume.letters.first.to.fetch(1)
    assert_operator behind.first.y + behind.first.height, :>, resume.letters.first.to.fetch(1)
  end

  # On a screen with twice the pixels each way, the menu is drawn at twice the pixels, so it is
  # the same size to the eye and sharper: here the bar, and the corner of the box under Game.
  def test_a_retina_screen_draws_the_menu_at_twice_the_pixels
    one = opened.drawing(width: 720, density: 1).grep(WindowMenu::Box)
    two = opened.drawing(width: 1440, density: 2).grep(WindowMenu::Box)

    assert_equal [0, 0, 1440, 44], [two[0].x, two[0].y, two[0].width, two[0].height]
    assert_equal [one[0].width * 2, one[0].height * 2], [two[0].width, two[0].height]
    lines_box = ->(boxes) { boxes.find { |box| box.color == WindowMenu::COLORS[:border] } }
    assert_equal [lines_box.call(one).x * 2, lines_box.call(one).y * 2], [lines_box.call(two).x, lines_box.call(two).y]
  end

  private

  def opened(**options)
    menu = Menu.new(**options)
    menu.toggle
    menu
  end

  def drawn_words(menu) = menu.drawing(width: 720, density: 1).grep(WindowMenu::Words)
end
