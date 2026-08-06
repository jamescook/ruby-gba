# frozen_string_literal: true

require "test_helper"

# repeat(n) { |i| } — the runtime counted loop. Assert its behavior: the body
# runs n times with the index counting 0..n-1, on the reference interpreter (the
# oracle) and on the console. The index is a Value, so it drives real positions.
class TestRepeat < Minitest::Test
  include RubyGBA::Constants

  # One green 2px mark per iteration, spaced 4 apart (2 drawn, 2 gap) so the
  # marks stay discrete: column = i * 4. After repeat(n) there are marks at
  # x = 0, 4, ... 4*(n-1); the gaps and the absence past the last prove the count.
  def marching_program(count)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      c = var :c, count
      repeat(:c) { |i| draw_rect_at i * 4, 40, 2, 2, :green }
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_interpreter_runs_the_body_once_per_index
    screen = Reference.new.run(marching_program(4)).screen

    # A mark at each of x = 0,4,8,12 (row 40)...
    [0, 4, 8, 12].each { |x| assert_equal Color.resolve(:green), screen.pixel(x, 40), "mark at x=#{x}" }
    assert_equal Color.resolve(:black), screen.pixel(2, 40), "a gap between marks"
    assert_equal Color.resolve(:black), screen.pixel(16, 40), "nothing past the last index"
  end

  def test_zero_count_runs_the_body_no_times
    screen = Reference.new.run(marching_program(0)).screen
    assert_equal Color.resolve(:black), screen.pixel(0, 40), "count 0 draws nothing"
  end

  def test_the_index_is_a_value_usable_in_expressions
    # column = i * 8, so marks land at x = 0, 8, 16 — i composes like any Value.
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      repeat(3) { |i| draw_rect_at i * 8, 40, 2, 2, :green }
      halt
    end
    builder.emit_pending_functions
    screen = Reference.new.run(builder.program).screen

    [0, 8, 16].each { |x| assert_equal Color.resolve(:green), screen.pixel(x, 40), "mark at x=#{x}" }
    assert_equal Color.resolve(:black), screen.pixel(4, 40), "gap between the i*8 marks"
  end

  def test_runs_on_hardware
    rom = RubyGBA::ROM.assemble(
      RubyGBA::IR::Backends::GBA.new.lower(marching_program(4)),
      title: "REPEAT", code: "BRPT", maker: "01",
    )
    v = assert_gemba_loads_rom(rom)
    assert v.green?(0, 40),  "first mark"
    assert v.green?(12, 40), "last mark (index 3)"
    assert v.black?(16, 40), "nothing past the last index"
  end
end
