# frozen_string_literal: true

require "test_helper"
require "differential"

# `keep_showing` — a picture drawn when it changes and then left there.
#
# The whole point of the verb is that the game never says how many times to paint.
# A tear-free screen keeps two pictures and shows them in turn, so a change drawn
# once flickers; a plain screen keeps one, so a change drawn once is done. The same
# game code has to be right on both, which is what these tests pin.
class TestKeepShowing < Minitest::Test
  include Differential
  include EmulatorSupport

  # A counter shown as a bar, repainted only when it changes. `bump` says when.
  # The bar is drawn over a field that is NOT repainted, which is what makes a
  # missed page visible: the old bar stays there.
  def counter_program(tear_free:, bump_on_frame: 2)
    b = Builder.new
    b.instance_eval do
      if tear_free
        screen :bitmap, tear_free: true
      else
        screen :bitmap
      end
      clear_screen :black

      n = var :n, 0
      shown = var :shown, 0
      bar = keep_showing(:bar) do
        fill_rect 0, 0, 240, 40, :black
        draw_rect_at 10, 10, 20, 20, :red
      end

      game_loop do
        n.add 1
        (n == bump_on_frame).then { shown.add 1; bar.changed }
        bar.draw
      end
    end
    b.emit_pending_functions
    [b.program, b]
  end

  # THE ONE THAT MATTERS. On a tear-free screen a change has to reach both pages,
  # so it is painted twice — and the proof is that the picture is there whichever
  # page you stop on. Stopping on an odd frame and an even frame both show it.
  def test_a_change_reaches_both_pages_of_a_tear_free_screen
    prog, = counter_program(tear_free: true)
    red = Color.resolve(:red)

    [6, 7].each do |frames|
      i = Reference.new.run(prog, frames: frames)
      assert_equal red, i.screen.pixel(15, 15),
                   "after #{frames} frames the bar should be on whichever page is showing"
    end
  end

  # ...and the console says so too, over the whole screen, on both parities.
  def test_the_console_agrees_on_both_parities
    prog, = counter_program(tear_free: true)
    assert_backends_agree(prog, frames: 6)
    assert_backends_agree(prog, frames: 7)
  end

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
        n.add 1
        (n == 2).then { draw_rect_at 10, 10, 20, 20, :red }
      end
    end
    b.emit_pending_functions

    red = Color.resolve(:red)
    on_page = [6, 7].map { |f| Reference.new.run(b.program, frames: f).screen.pixel(15, 15) == red }
    assert_equal 1, on_page.count(true),
                 "a single paint should show on exactly one of the two pages, got #{on_page.inspect}"
  end

  # The same game code on a plain screen: one page, so one paint, and the picture
  # is there on every frame. Nothing in the program said which screen it was on.
  def test_the_same_code_is_right_on_a_plain_screen
    prog, = counter_program(tear_free: false)
    red = Color.resolve(:red)

    [6, 7].each do |frames|
      i = Reference.new.run(prog, frames: frames)
      assert_equal red, i.screen.pixel(15, 15)
    end
  end

  # How many paints each screen asks for, said out loud — the fact the game never
  # has to write down.
  def test_the_screen_decides_how_many_paints_a_change_takes
    _, tear_free = counter_program(tear_free: true)
    _, plain = counter_program(tear_free: false)

    assert_equal 2, tear_free.keep_showing_pictures[:bar].pages
    assert_equal 1, plain.keep_showing_pictures[:bar].pages
  end

  # A frame where nothing changed does no drawing at all. Asserted through the
  # picture rather than the tree: the field the routine paints over is left alone,
  # so something drawn on top of it after the last change survives.
  def test_a_frame_with_no_change_does_not_repaint
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      bar = keep_showing(:bar) { fill_rect 0, 0, 240, 40, :red }
      game_loop do
        n.add 1
        (n == 1).then { bar.changed }
        bar.draw
        (n == 3).then { draw_rect_at 100, 10, 20, 20, :green }
      end
    end
    b.emit_pending_functions

    i = Reference.new.run(b.program, frames: 8)
    assert_equal Color.resolve(:green), i.screen.pixel(105, 15),
                 "the green mark drawn after the last change should still be there"
    assert_equal Color.resolve(:red), i.screen.pixel(10, 15), "...over the bar it was drawn on"
  end

  # ---- the friendly errors ----

  def test_declaring_the_same_picture_twice_is_a_friendly_error
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        keep_showing(:bar) { fill_rect 0, 0, 10, 10, :red }
        keep_showing(:bar) { fill_rect 0, 0, 10, 10, :blue }
      end
    end
    assert_match(/declared twice/, error.message)
  end

  def test_a_picture_with_no_block_is_a_friendly_error
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        keep_showing(:bar)
      end
    end
    assert_match(/needs a block/, error.message)
  end

  def test_a_picture_with_no_name_is_a_friendly_error
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        keep_showing("bar") { fill_rect 0, 0, 10, 10, :red }
      end
    end
    assert_match(/needs a name/, error.message)
  end

  # Declared and told when it changes, but never drawn — the half-written shape,
  # where the picture simply never appears.
  def test_a_picture_that_is_never_drawn_is_a_friendly_warning
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      bar = keep_showing(:bar) { fill_rect 0, 0, 240, 40, :red }
      game_loop { bar.changed }
    end
    b.emit_pending_functions

    findings = RubyGBA::Effects::Packs::KeepShowing::NeverDrawn.new.detect(b.program)
    assert_equal 1, findings.length
    assert_match(/never draws that picture/, findings.first.message)
    assert_equal :warning, findings.first.severity
  end

  def test_a_picture_that_is_drawn_raises_no_warning
    prog, = counter_program(tear_free: true)
    assert_empty RubyGBA::Effects::Packs::KeepShowing::NeverDrawn.new.detect(prog)
  end
end
