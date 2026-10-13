# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# How a program zig built is run and read back (Native::Zig.run_program).
class TestNativeZig < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  Zig = RubyGBA::IR::Backends::Native::Zig

  # Ruby threads that do nothing but count, for as long as the block runs: what the tests beside
  # this one are doing whenever they replay a game on the interpreter.
  def beside_busy_threads(count)
    stop = false
    busy = Array.new(count) { Thread.new { nil until stop } }
    yield
  ensure
    stop = true
    busy.each(&:join)
  end

  # A PROGRAM'S RUN DOES NOT WAIT ON RUBY. Ruby runs one thread at a time, and a thread reading
  # what a program prints as it prints it takes its turn again for every piece, behind every
  # thread that is busy. A native run puts tests side by side, so a program that ends in a
  # second took minutes that way, with its output backed up behind a reader waiting its turn,
  # and was stopped as one that never ends.
  def test_a_program_that_prints_a_lot_ends_in_time_beside_busy_ruby_threads
    program = program_of do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :red
        n.add! 1
      end
    end
    exe = Native.new.build_headless(program, mode: :checked)
    frames = 60

    printed = beside_busy_threads(3) do
      Zig.run_program(exe, args: [frames, "--every-picture"], input: "0\n" * frames, seconds: 15)
    end

    assert_equal frames, printed.scan(/^frame \d+$/).length, "every frame should have been printed"
    assert_operator printed.bytesize, :>, 5_000_000, "and the run should have been one that prints a great deal"
  end
end
