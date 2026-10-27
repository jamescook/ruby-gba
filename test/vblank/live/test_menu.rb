# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The menu over the window a game is played in: a few lines, one chosen, moved through with the
# arrows and done with Enter. These play it with no window at all; the window only draws its
# lines and does what its settings say.
class TestMenu < Minitest::Test
  Menu = VBlank::Live::Menu

  def test_a_menu_starts_closed_with_the_desktop_builds_settings
    menu = Menu.new

    refute menu.open?
    assert_equal({ fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false, frame_rate: false },
                 menu.settings.to_h)
  end

  def test_a_menu_opens_on_resume_and_says_each_setting
    menu = Menu.new(scale: 2)
    menu.toggle

    assert menu.open?
    assert_equal ["> Resume", "  Fast forward  4x", "  Window size   2x", "  Fullscreen   off", "  Volume       100",
                  "  Mute         off", "  Frame rate   off", "  Quit"], menu.lines
  end

  # Up and down choose a line, going round at either end; left and right change what it holds,
  # never past what it can be.
  def test_the_arrows_choose_a_line_and_change_it
    menu = Menu.new
    menu.toggle
    menu.press(:down)
    5.times { menu.press(:right) }
    menu.press(:down)
    3.times { menu.press(:left) }
    menu.press(:up)
    menu.press(:up)
    menu.press(:up)

    assert_equal 8, menu.settings.fast_forward_speed
    assert_equal 1, menu.settings.scale
    assert_equal "> Quit", menu.lines.last
  end

  def test_enter_switches_a_setting_on_and_off
    menu = Menu.new
    menu.toggle
    3.times { menu.press(:down) }
    menu.press(:enter)

    assert menu.settings.fullscreen
    assert_equal "> Fullscreen    on", menu.lines[3]
  end

  def test_volume_goes_in_tens
    menu = Menu.new
    menu.toggle
    4.times { menu.press(:down) }
    3.times { menu.press(:left) }

    assert_equal 70, menu.settings.volume
  end

  def test_enter_on_resume_closes_the_menu_and_on_quit_asks_to_stop
    menu = Menu.new
    menu.toggle
    menu.press(:enter)
    refute menu.open?

    menu.toggle
    menu.press(:up)
    menu.press(:enter)
    assert menu.quit?
  end

  # A menu opened again starts on Resume, so a second press of the menu key and Enter carries on.
  def test_a_menu_opens_again_on_resume
    menu = Menu.new
    menu.toggle
    menu.press(:down)
    menu.toggle
    menu.toggle

    assert_equal "> Resume", menu.lines.first
  end
end
