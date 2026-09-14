# frozen_string_literal: true

require "test_helper"
require "differential"

# The expression DSL: `var` hands back a Value handle you compare with ordinary
# Ruby operators to get a Condition, branch on with .then / .else, compose with
# & / |, and change a variable with .set! / .add! / .sub! / .clamp! / .abs! / ....
#
# These tests assert BEHAVIOR, not tree shape: a tiny program is built through
# the DSL, run on the reference backend's fake screen, and checked by the pixels
# it drew. So a comparison or branch is judged by what it makes the game show —
# never by re-describing the IR it builds. (Opcode-level checks belong in the
# IR-backend tests.) Guardrail tests assert a friendly error for misuse, and a
# couple of the emulator tests confirm the same programs on real hardware.
class TestDSLExpression < Minitest::Test
  include RubyGBA::IR::Build # constructors, for the guardrail trees
  include Differential

  # Build through the DSL and run it on the reference backend, returning the
  # interpreter — whose #screen holds the pixels the program drew. `held` pins a
  # button down for the whole run; `each_frame` supplies per-frame input.
  def interpret(held: nil, each_frame: nil, **opts, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions

    ruby = Reference.new
    ruby = ruby.hold(held) if held
    ruby = ruby.input_each_frame(&each_frame) if each_frame
    ruby.run(builder.program, **opts)
    ruby
  end

  # Build a real ROM (for the emulator-backed hardware-confirmation tests).
  def build(&block)
    RubyGBA.build("EXPR", code: "BEXP", maker: "01", validate: false, &block)
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
      v.set! 5
      v.add! 3
      v.sub! 1
      v.clamp! 0, 5
      draw_rect_at :v, 20, 2, 2, :green # a variable position: x comes from v
    end
    assert_equal Color.resolve(:green), pixel_at(i, 5, 20)
    assert_equal UNDRAWN, pixel_at(i, 8, 20), "the pre-clamp 8 is not where it landed"
  end

  # A word that changes a variable ends in `!`, on the handle and as a flat verb alike.
  def test_the_words_that_change_a_variable_end_in_bang
    i = interpret do
      v = var :v, 0
      v.set! 5
      v.add! 3
      v.sub! 1
      copy! :w, :v
      add! :w, 10
      sub! :w, 2
      set! :z, 1
      draw_rect_at :v, 20, 2, 2, :green # 7
      draw_rect_at :w, 30, 2, 2, :white # 15
      draw_rect_at :z, 40, 2, 2, :blue  # 1
    end

    assert_equal Color.resolve(:green), pixel_at(i, 7, 20)
    assert_equal Color.resolve(:white), pixel_at(i, 15, 30)
    assert_equal Color.resolve(:blue), pixel_at(i, 1, 40)
  end

  # ...and the same words without it say so rather than changing anything.
  [%i[set 5], %i[add 1], %i[sub 1]].each do |word, amount|
    define_method(:"test_a_variables_#{word}_without_its_bang_is_a_friendly_error") do
      err = assert_raises(ArgumentError) { tree { var(:v, 0).public_send(word, amount) } }

      assert_match(/`v\.#{word}` does not change a variable/, err.message)
      assert_match(/write `v\.#{word}!`/, err.message)
    end
  end

  def test_a_flat_verb_without_its_bang_is_a_friendly_error
    err = assert_raises(ArgumentError) { tree { copy :w, :v } }

    assert_match(/`copy :w, :v` does not change a variable/, err.message)
    assert_match(/write `copy! :w, :v`/, err.message)
  end

  # `add` and `sub` have a Ruby operator that makes a new number, so the message offers it.
  def test_add_and_sub_point_at_the_operator_that_makes_a_new_number
    add = assert_raises(ArgumentError) { tree { var(:v, 0).add 1 } }
    sub = assert_raises(ArgumentError) { tree { var(:v, 0).sub 1 } }

    assert_match(/`v \+ 1`/, add.message)
    assert_match(/`v - 1`/, sub.message)
  end

  def test_unary_mutators_change_the_variable
    # d = -3; abs -> 3; +20 keeps the marker on-screen at x = 23.
    i = interpret do
      d = var :d, -3
      d.abs!
      d.add! 20
      draw_rect_at :d, 30, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 23, 30)
  end

  # Read as Ruby reads it, `d.abs <= 5` asks how far d is from nought and leaves d alone — the
  # way Integer#abs does. So the comparison holds, and d is still negative after it.
  def test_abs_inside_a_comparison_leaves_the_variable_alone
    i = interpret do
      d = var :d, -3
      (d.abs <= 5).then { pixel 1, 1, :red }
      (d < 0).then { pixel 2, 2, :blue }
    end
    assert_equal Color.resolve(:red), pixel_at(i, 1, 1), "3 is within 5"
    assert_equal Color.resolve(:blue), pixel_at(i, 2, 2), "d is still -3"
  end

  # THE FIVE AS NEW NUMBERS, each the number its `!` word would store, with d left at -3.
  # Each answer is drawn as a mark at x = 40 + answer on its own row, so a wrong one lands
  # in the wrong column. A bound and a step the game works out take a different path from
  # ones written down, so both are here.
  NEW_NUMBERS = [
    [3,   ->(d, _t, _s) { d.abs }],
    [0,   ->(d, _t, _s) { d.clamp(0, 9) }],
    [9,   ->(d, _t, _s) { (d + 20).clamp(0, 9) }],
    [-3,  ->(d, t, _s) { d.clamp(t - 20, t) }],        # already inside bounds worked out
    [1,   ->(d, t, _s) { d.approach(t, 4) }],
    [-1,  ->(d, t, s) { d.approach(t, s) }],           # a step of -2 read as a distance
    [-4,  ->(d, _t, _s) { d.approach(-4, 4) }],        # within a step: lands on it
    [3,   ->(d, _t, _s) { d.flip }],
    [-3,  ->(d, _t, _s) { d.negate_abs }],
    [-7,  ->(d, _t, _s) { (d + 10).negate_abs }],
    [-3,  ->(d, _t, _s) { d }],                        # and d itself, untouched
  ].freeze

  def new_numbers_program(builder)
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      d = var :d, -3
      t = var :t, 10
      s = var :s, -2
      out = var :out, 0
      NEW_NUMBERS.each_with_index do |(_, number), row|
        out.set! number.call(d, t, s)
        draw_rect_at out + 40, row * 4, 2, 2, :white
      end
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_five_words_without_bang_are_new_numbers_on_both_backends
    program = new_numbers_program(Builder.new)
    i = Reference.new.run(program)

    NEW_NUMBERS.each_with_index do |(want, _), row|
      assert_equal Color.resolve(:white), pixel_at(i, 40 + want, row * 4), "row #{row} is #{want}"
    end
    assert_backends_agree(program, frames: 2)
  end

  # A number that holds a fraction keeps it: |-1.5| is 1.5, not 1 or 2.
  def test_a_new_number_keeps_the_fraction
    i = interpret do
      d = var :d, -1.5
      (d.abs > 1.25).then { pixel 1, 1, :red }
      (d.abs < 1.75).then { pixel 2, 2, :red }
      (d.clamp(-1.0, 1.0) == -1.0).then { pixel 3, 3, :red }
    end

    [1, 2, 3].each { |at| assert_equal Color.resolve(:red), pixel_at(i, at, at) }
  end

  def test_flip_reverses_the_sign
    # d = 5; flip -> -5; +25 brings the marker back on-screen at x = 20.
    i = interpret do
      d = var :d, 5
      d.flip!
      d.add! 25
      draw_rect_at :d, 40, 2, 2, :white
    end
    assert_equal Color.resolve(:white), pixel_at(i, 20, 40)
  end

  # `flip` mutates a variable in place; unary minus is the same idea as an EXPRESSION —
  # `-speed` reads as far backwards as `speed` reads forwards, without disturbing speed.
  # It is what you reach for writing a wave that runs the other way.
  def test_unary_minus_is_the_value_the_other_way_round
    # d stays 5; the marker's x is 25 + (-5) = 20, so reading the marker proves both that
    # the sign flipped and that d itself was left alone.
    i = interpret do
      d = var :d, 5
      m = var :m, 0
      m.set!(25 + -d)
      draw_rect_at :m, 40, 2, 2, :white
      draw_rect_at :d, 60, 2, 2, :green
    end
    assert_equal Color.resolve(:white), pixel_at(i, 20, 40)
    assert_equal Color.resolve(:green), pixel_at(i, 5, 60), "d was not changed by reading -d"
  end

  def test_division_truncates_toward_zero
    # 20 / 3 = 6 (truncated, not 6.66); the marker's x reveals the quotient.
    i = interpret do
      x = var :x, 20
      q = var :q, 0
      q.set!(x / 3)
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
      q.set!(n / 2)
      q.add! 30
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
        pressed(:start).then { n.add! 1 }
        (n == 1).then { pixel 10, 10, :red }
        (n >= 2).then { pixel 20, 20, :blue }
        f.add! 1
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
        (x + 1).add! 2 # (x + 1) is an expression, not a variable — can't mutate it
      end
    end
    assert_match(/variable/, err.message)
  end

  # ---- the same programs, confirmed on real hardware (the emulator) ----

  def test_then_gates_a_draw_on_hardware
    rom = build do
      screen :bitmap
      clear_screen :black
      x = var :x, 5
      (x > 3).then { pixel 10, 10, :red }
      (x < 3).then { pixel 20, 20, :blue }
      halt
    end
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 10)
    assert v.black?(20, 20)
  end

  def test_and_else_on_hardware
    rom = build do
      screen :bitmap
      clear_screen :black
      x = var :x, 5
      ((x > 1) & (x < 9)).then { pixel 10, 10, :red }.else { pixel 20, 20, :blue }
      halt
    end
    v = assert_emulator_loads_rom(rom)
    assert v.red?(10, 10), "5 is in (1, 9), so the then-branch draws"
    assert v.black?(20, 20)
  end
end
