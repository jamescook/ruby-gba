# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The Ruby backend's simulated hardware: run hand-built IR programs that draw and
# read input, then assert what landed on the fake screen and which branch a
# supplied button state took. Still no emulator and no ROM — the point is that a
# game's *visible* behavior is assertable in-process.
class TestIRBackendRubyHardware < Minitest::Test
  include RubyGBA::IR::Build

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  def run_ir(node, **opts)
    Ruby.new.run(node, **opts)
  end

  # ---- drawing into the framebuffer ----

  def test_clear_screen_paints_the_whole_screen
    i = run_ir(program(display(:bitmap), clear_screen(:blue)))
    assert_equal Color.resolve(:blue), i.screen.pixel(0, 0)
    assert_equal Color.resolve(:blue), i.screen.pixel(239, 159)
  end

  def test_pixel_writes_a_resolved_color_at_coordinates
    i = run_ir(program(pixel(10, 20, :red)))
    assert_equal Color.resolve(:red), i.screen.pixel(10, 20)
    assert_equal 0, i.screen.pixel(11, 20) # neighbor untouched
  end

  def test_pixel_coordinates_can_come_from_variables
    i = run_ir(program(
      set(:px, 100),
      set(:py, 50),
      pixel(:px, :py, :green),
    ))
    assert_equal Color.resolve(:green), i.screen.pixel(100, 50)
  end

  def test_fill_rect_paints_a_block
    i = run_ir(program(fill_rect(5, 5, 3, 2, :yellow)))
    assert_equal Color.resolve(:yellow), i.screen.pixel(5, 5)
    assert_equal Color.resolve(:yellow), i.screen.pixel(7, 6) # bottom-right
    assert_equal 0, i.screen.pixel(8, 5)                      # just outside
  end

  def test_off_screen_pixel_is_clipped_without_error
    # The safe-by-default promise: a stray coordinate can't crash a program.
    i = run_ir(program(pixel(999, 999, :red)))
    assert_equal 0, i.screen.pixel(0, 0)
  end

  def test_display_mode_is_recorded
    i = run_ir(program(display(:bitmap)))
    assert_equal :bitmap, i.display_mode
  end

  # ---- reading input ----

  def test_held_button_takes_the_branch
    i = Ruby.new.hold(:a).run(program(
      if_(held(:a), set(:jumped, 1)),
      if_(held(:b), set(:shot, 1)),
    ))
    assert_equal 1, i[:jumped]
    assert_equal 0, i[:shot]
  end

  def test_unheld_button_skips_the_branch
    i = Ruby.new.run(program(if_(held(:up), set(:moved, 1))))
    assert_equal 0, i[:moved]
  end

  def test_pressed_is_an_edge_only_the_first_frame_a_button_is_down
    # Button :a is held on every frame, but "pressed" should fire once — the
    # frame the button first goes down, not while it stays down.
    i = Ruby.new.input_each_frame { |_frame| [:a] }.run(program(
      set(:count, 0),
      set(:presses, 0),
      loop_(
        wait_vblank,
        if_(pressed(:a), add(:presses, 1)),
        add(:count, 1),
        if_(binop(:>=, var_ref(:count), int(3)), halt),
      ),
    ))
    assert_equal 3, i[:count]
    assert_equal 1, i[:presses]
  end

  def test_unknown_button_is_a_friendly_error
    err = assert_raises(Ruby::ProgramError) do
      Ruby.new.run(program(if_(held(:triangle), set(:x, 1))))
    end
    assert_match(/triangle/, err.message)
  end

  # ---- observation log ----

  def test_log_records_vblank_ticks_and_halt
    i = run_ir(program(
      set(:x, 0),
      loop_(
        wait_vblank,
        add(:x, 1),
        if_(binop(:>=, var_ref(:x), int(2)), halt),
      ),
    ))
    assert_equal [[:vblank, 1], [:vblank, 2], [:halt]], i.log
  end
end
