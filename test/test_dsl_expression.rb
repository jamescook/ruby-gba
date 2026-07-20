# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The expression DSL: `var` hands back a Value handle you compare with ordinary
# Ruby operators to get a Condition, branch on with .then / .else, compose with
# & / |, and mutate with .set / .add / .sub / .clamp / .abs / ....
#
# These tests assert BEHAVIOR, not tree shape: a tiny program is built through
# the DSL, run on the reference backend's fake screen, and checked by the pixels
# it drew. So a comparison or branch is judged by what it makes the game show —
# never by re-describing the IR it builds. (Opcode-level checks belong in the
# IR-backend tests.) Guardrail tests assert a friendly error for misuse, and a
# couple of gemba tests confirm the same programs on real hardware.
class TestDSLExpression < Minitest::Test
  include RubyGBA::IR::Build # constructors, for the guardrail trees
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  # Build through the DSL and run it on the reference backend, returning the
  # interpreter — whose #screen holds the pixels the program drew. `held` pins a
  # button down for the whole run; `each_frame` supplies per-frame input.
  def interpret(held: nil, each_frame: nil, **opts, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions

    ruby = Ruby.new
    ruby = ruby.hold(held) if held
    ruby = ruby.input_each_frame(&each_frame) if each_frame
    ruby.run(builder.program, **opts)
    ruby
  end

  # Build a real ROM (for the gemba hardware-confirmation tests).
  def build(&block)
    RubyGBA.build("EXPR", code: "BEXP", maker: "01", doctor: false, &block)
  end

  # Build the IR tree without running it — only the guardrail tests need this, to
  # see that a bad call raises before anything executes.
  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def pixel_at(interp, x, y)
    interp.screen.pixel(x, y)
  end

  UNDRAWN = 0 # the fake screen starts blank; an untouched pixel reads 0

  # ---- a comparison gates a draw ----

  def test_a_true_comparison_draws_and_a_false_one_does_not
    i = interpret do
      x = var :x, 5
      (x > 3).then { pixel 10, 10, :red }  # 5 > 3 — draws
      (x < 3).then { pixel 20, 20, :blue } # 5 < 3 is false — skipped
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_each_comparison_operator_gates_correctly
    # Boundary rows (the equal case) separate > from >=, < from <=, and so on.
    # Red appears only when the comparison actually holds.
    [
      [:>,  5, 3, true],  [:>,  3, 3, false],
      [:<,  3, 5, true],  [:<,  3, 3, false],
      [:>=, 3, 3, true],  [:>=, 2, 3, false],
      [:<=, 3, 3, true],  [:<=, 4, 3, false],
      [:==, 3, 3, true],  [:==, 3, 4, false],
      [:!=, 3, 4, true],  [:!=, 3, 3, false],
    ].each do |op, a, b, holds|
      i = interpret do
        x = var :x, a
        x.public_send(op, b).then { pixel 1, 1, :red }
      end
      expected = holds ? Color.resolve(:red) : UNDRAWN
      assert_equal expected, pixel_at(i, 1, 1), "#{a} #{op} #{b} should be #{holds}"
    end
  end

  def test_arithmetic_feeds_a_comparison
    draw = lambda do |y_start|
      interpret do
        c = var :c, 5
        y = var :y, y_start
        (y > c + 10).then { pixel 2, 2, :red } # threshold is c + 10 = 15
      end
    end
    assert_equal Color.resolve(:red), pixel_at(draw.call(20), 2, 2), "20 > 15 draws"
    assert_equal UNDRAWN, pixel_at(draw.call(12), 2, 2), "12 > 15 is false"
  end

  # ---- mutators, observed by where/whether the mark lands ----

  def test_value_mutators_change_the_variable
    # v walks 0 -> 5 -> 8 -> 7, then clamps down to 5; the marker's x reveals it.
    i = interpret do
      v = var :v, 0
      v.set 5
      v.add 3
      v.sub 1
      v.clamp 0, 5
      draw_rect_at :v, 20, 2, 2, :green # a variable position: x comes from v
    end
    assert_equal Color.resolve(:green), pixel_at(i, 5, 20)
    assert_equal UNDRAWN, pixel_at(i, 8, 20), "the pre-clamp 8 is not where it landed"
  end

  def test_unary_mutators_change_the_variable
    # d = -3; abs -> 3; +20 keeps the marker on-screen at x = 23.
    i = interpret do
      d = var :d, -3
      d.abs
      d.add 20
      draw_rect_at :d, 30, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 23, 30)
  end

  def test_flip_reverses_the_sign
    # d = 5; flip -> -5; +25 brings the marker back on-screen at x = 20.
    i = interpret do
      d = var :d, 5
      d.flip
      d.add 25
      draw_rect_at :d, 40, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 20, 40)
  end

  def test_division_truncates_toward_zero
    # 20 / 3 = 6 (truncated, not 6.66); the marker's x reveals the quotient.
    i = interpret do
      x = var :x, 20
      q = var :q, 0
      q.set(x / 3)
      draw_rect_at :q, 10, 2, 2, :green
    end
    # The marker's left edge sits at x = q. green at 6 and blank at 5 pins q = 6
    # (7/... i.e. an untruncated 6.66 rounded up to 7 would leave 6 blank).
    assert_equal Color.resolve(:green), pixel_at(i, 6, 10)
    assert_equal UNDRAWN, pixel_at(i, 5, 10)
  end

  def test_dividing_a_negative_truncates_toward_zero_not_down
    # -7 / 2 = -3 on hardware (toward zero), not -4 (Ruby's floor). +30 keeps the
    # marker on-screen: -3 + 30 = 27, whereas a floored -4 would land at 26.
    i = interpret do
      n = var :n, -7
      q = var :q, 0
      q.set(n / 2)
      q.add 30
      draw_rect_at :q, 20, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 27, 20)
    assert_equal UNDRAWN, pixel_at(i, 26, 20), "a floored -4 would land here"
  end

  # ---- .then { } / .else { } ----

  def test_then_draws_when_true
    i = interpret do
      x = var :x, 9
      (x > 5).then { pixel 10, 10, :red }.else { pixel 20, 20, :blue }
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_else_draws_when_false
    i = interpret do
      x = var :x, 1
      (x > 5).then { pixel 10, 10, :red }.else { pixel 20, 20, :blue }
    end
    assert_equal Color.resolve(:blue), pixel_at(i, 20, 20)
    assert_equal UNDRAWN, pixel_at(i, 10, 10)
  end

  # ---- & / | condition composition ----

  def test_and_needs_both_conditions
    i = interpret do
      x = var :x, 5
      ((x > 1) & (x < 9)).then { pixel 10, 10, :red }  # 5 is in range
      ((x > 1) & (x > 9)).then { pixel 20, 20, :blue } # 5 is not > 9
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  def test_or_needs_either_condition
    i = interpret do
      x = var :x, 5
      ((x > 9) | (x < 9)).then { pixel 10, 10, :red }  # 5 < 9
      ((x > 9) | (x < 0)).then { pixel 20, 20, :blue } # 5 is neither
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10)
    assert_equal UNDRAWN, pixel_at(i, 20, 20)
  end

  # ---- input: held / pressed ----

  def test_held_draws_only_while_the_button_is_down
    down = interpret(held: :up) do
      held(:up).then { pixel 10, 10, :red }
    end
    assert_equal Color.resolve(:red), pixel_at(down, 10, 10)

    up = interpret do
      held(:up).then { pixel 10, 10, :red }
    end
    assert_equal UNDRAWN, pixel_at(up, 10, 10)
  end

  def test_pressed_fires_once_on_the_down_edge
    # :start is held every frame, but `pressed` is the edge — it fires once, so
    # the counter reaches 1 and stays there. Red marks "n == 1"; blue marks
    # "n >= 2", which must never appear if holding isn't counted as repeats.
    i = interpret(each_frame: ->(_frame) { [:start] }) do
      n = var :n, 0
      f = var :f, 0
      game_loop do
        wait_vblank
        pressed(:start).then { n.add 1 }
        (n == 1).then { pixel 10, 10, :red }
        (n >= 2).then { pixel 20, 20, :blue }
        f.add 1
        (f >= 4).then { halt }
      end
    end
    assert_equal Color.resolve(:red), pixel_at(i, 10, 10), "one down-edge => n == 1"
    assert_equal UNDRAWN, pixel_at(i, 20, 20), "holding is not repeated presses"
  end

  # ---- guardrails: misuse is a plain error, not a silent drop ----

  def test_held_and_pressed_reject_a_block
    # Forgetting .then and writing held(:up) { ... } drops the block silently
    # (it attaches to `held`, not to an if). Catch it at the call site.
    %i[held pressed].each do |verb|
      err = assert_raises(ArgumentError) do
        tree { send(verb, :up) { halt } }
      end
      assert_match(/\.then/, err.message, "#{verb} should point the dev at .then")
    end
  end

  def test_held_rejects_an_unknown_button
    assert_raises(ArgumentError) { tree { held(:turbo).then { halt } } }
  end

  def test_then_requires_a_block
    err = assert_raises(ArgumentError) do
      tree { (var(:x, 0) > 0).then }
    end
    assert_match(/block/, err.message)
  end

  def test_else_requires_a_block
    err = assert_raises(ArgumentError) do
      tree { (var(:x, 0) > 5).then { halt }.else }
    end
    assert_match(/block/, err.message)
  end

  def test_composing_with_a_non_condition_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        ((x > 1) & x).then { halt } # x is a Value, not a Condition
      end
    end
    assert_match(/condition/i, err.message)
  end

  def test_mutating_an_expression_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        (x + 1).add 2 # (x + 1) is an expression, not a variable — can't mutate it
      end
    end
    assert_match(/variable/, err.message)
  end

  # ---- the same programs, confirmed on real hardware (gemba) ----

  def test_then_gates_a_draw_on_hardware
    rom = build do
      display :bitmap
      clear_screen :black
      x = var :x, 5
      (x > 3).then { pixel 10, 10, :red }
      (x < 3).then { pixel 20, 20, :blue }
      halt
    end
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 10)
    assert v.black?(20, 20)
  end

  def test_and_else_on_hardware
    rom = build do
      display :bitmap
      clear_screen :black
      x = var :x, 5
      ((x > 1) & (x < 9)).then { pixel 10, 10, :red }.else { pixel 20, 20, :blue }
      halt
    end
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 10), "5 is in (1, 9), so the then-branch draws"
    assert v.black?(20, 20)
  end
end
