# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The `table` verb: a build-time Ruby array shipped as read-only ROM data, read at
# run time by a Value index. These assert the observable value a lookup returns on
# the reference interpreter — the fast oracle — including signedness and the
# out-of-range safety rule. The hardware lowering is checked with gemba separately.
class TestTable < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  def interpret(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    Ruby.new.run(b.program)
  end

  def rom_for(title, code, &block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    ROM.assemble(GBA.new.lower(b.program), title: title, code: code, maker: "01")
  end

  def test_reads_a_value_at_a_constant_index
    i = interpret do
      squares = table :squares, [0, 1, 4, 9, 16, 25], width: :byte
      var :out, 0
      set :out, squares[3]
      halt
    end
    assert_equal 9, i[:out]
  end

  def test_reads_at_a_runtime_index
    i = interpret do
      t = table :t, [10, 20, 30, 40], width: :byte
      idx = var :idx, 2
      var :out, 0
      set :out, t[idx]
      halt
    end
    assert_equal 30, i[:out]
  end

  def test_signed_values_round_trip
    i = interpret do
      t = table :sines, [0, 127, -128, -1], width: :byte # signed is inferred (a negative present)
      var :out, 0
      set :out, t[2]
      halt
    end
    assert_equal(-128, i[:out])
  end

  # A halfword sine table scaled to +/-256: read a known entry.
  def test_a_build_time_sine_table
    i = interpret do
      sin = table :sin, (0...256).map { |a| (Math.sin(a * Math::PI / 128) * 256).round }, width: :half
      var :q, 64
      var :out, 0
      set :out, sin[:q] # sin at a quarter turn (64/256) is the peak, +256
      halt
    end
    assert_equal 256, i[:out]
  end

  def test_power_of_two_table_wraps_the_index
    i = interpret do
      t = table :t, [100, 200, 300, 400], width: :half # 4 entries: index 5 wraps to 1
      var :out, 0
      set :out, t[5]
      halt
    end
    assert_equal 200, i[:out]
  end

  def test_non_power_of_two_table_clamps_the_index
    i = interpret do
      t = table :t, [7, 8, 9], width: :half # 3 entries: past-the-end clamps to the last, below-zero to the first
      var :hi, 0
      var :lo, 0
      set :hi, t[9]
      set :lo, t[-4]
      halt
    end
    assert_equal 9, i[:hi]
    assert_equal 7, i[:lo]
  end

  # --- Guardrails ---

  def test_a_value_too_big_for_the_width_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [0, 300], width: :byte } # 300 > 255
    end
    assert_match(/does not fit/, err.message)
  end

  def test_a_bad_width_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [1, 2], width: :quad }
    end
    assert_match(/:byte, :half, or :word/, err.message)
  end

  def test_non_integer_values_are_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { table :t, [1, 2.5], width: :half }
    end
    assert_match(/whole numbers/, err.message)
  end

  # --- Hardware (gemba): the lookup drives real pixels ---

  # A table of x-positions drives a rect's position on the console: the rect lands at
  # the value the lookup returned, proving the runtime read works on hardware.
  def test_a_table_value_positions_a_rect_on_the_console
    rom = rom_for("TABLE", "BTBL") do
      screen :bitmap
      clear_screen :black
      xs = table :xs, [10, 80, 150], width: :half # non-power-of-two -> clamps
      draw_rect_at xs[1], 40, 8, 8, :white         # a white 8x8 at x = xs[1] = 80
      halt
    end
    v = assert_gemba_loads_rom(rom, frames: 2)
    assert v.white?(83, 43), "the rect drew at the table's x (80), got 0x#{format('%04X', v.pixel_gba(83, 43))}"
    assert v.black?(20, 43), "elsewhere stays background"
  end

  # A signed table read must sign-extend on hardware (the ldrsh path): a negative
  # offset moves the rect UP from a base y, so a wrong (unsigned) read would misplace it.
  def test_a_signed_table_read_sign_extends_on_the_console
    rom = rom_for("TSIGN", "BTSG") do
      screen :bitmap
      clear_screen :black
      dy = table :dy, [-24, 0, 24], width: :half # signed inferred; index 0 is -24
      var :y, 80
      add :y, dy[0]                               # y = 80 + (-24) = 56
      draw_rect_at 100, :y, 8, 8, :white
      halt
    end
    v = assert_gemba_loads_rom(rom, frames: 2)
    assert v.white?(103, 59), "a signed -24 moved the rect to y=56, got 0x#{format('%04X', v.pixel_gba(103, 59))}"
    assert v.black?(103, 83), "the rect is not at the base y (80)"
  end
end
