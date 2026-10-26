# frozen_string_literal: true

require "test_helper"

# The game written as JavaScript: what the JavaScript lowering does that the native one does not.
# The statements are the native lowering's own, printed another way, so what is checked here is
# the printing — chiefly how a routine waits for the next frame, which a browser cannot do the way
# C does — and what the browser build refuses.
class TestJSLowering < Minitest::Test
  JS = VBlank::IR::Backends::JS
  HeadlessRun = JS::HeadlessRun

  # A game built through the DSL; +manual+ places the waits for the screen where the game says.
  private def program_of(manual: false, &block)
    options = VBlank::Cartridge::Options.new(frame_sync: manual ? :manual : :auto)
    builder = Builder.new(options: options)
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # A routine that can reach a wait for the screen is a generator, and is delegated to where it is
  # called; one that never waits stays a plain function, called plainly.
  def test_only_a_routine_that_can_wait_is_a_generator
    source = JS.new.lower(program_of(manual: true) do
      screen :bitmap
      steps = var :steps, 0
      func(:draw) { fill_rect 0, 0, 8, 8, :red }
      func(:pause) { wait_vblank }
      func(:walk) do
        steps.add! 1
        call :pause
      end
      game_loop do
        call :draw
        call :walk
      end
    end)

    assert_match(/^function f_draw\(\)/, source)
    assert_match(/^function\* f_pause\(\)/, source)
    assert_match(/^function\* f_walk\(\)/, source, "a routine that calls one that waits waits too")
    assert_match(/yield\* f_walk\(\);/, source)
    assert_match(/^\s+f_draw\(\);/, source)
  end

  # A wait deep inside a routine ends the frame from there, and the game takes up where it left
  # off, as the interpreter does.
  def test_a_wait_inside_a_routine_ends_the_frame_there
    program = program_of(manual: true) do
      screen :bitmap
      before = var :before, 0
      after = var :after, 0
      func(:pause) do
        before.add! 1
        wait_vblank
        after.add! 1
      end
      game_loop { call :pause }
    end
    run = game_player.run(program, frames: 4)

    # Four frames played and the fifth reached: five waits begun, four come back from.
    assert_equal [5, 4], [run[:before], run[:after]]
  end

  # A routine picked by a number waits too when any routine it can pick waits, since a call
  # through the list cannot tell which it reaches.
  def test_a_routine_picked_by_number_can_wait
    program = program_of(manual: true) do
      screen :bitmap
      which = var :which, 0
      count = var :count, 0
      func(:quick) { count.add! 1 }
      func(:slow) do
        count.add! 10
        wait_vblank
      end
      game_loop do
        call %i[quick slow], number: which
        which.set! 1
      end
    end
    source = JS.new.lower(program)

    assert_match(/^function\* f_quick\(\)/, source, "both can be picked, so both are generators")
    played = game_player.run(program, frames: 3)
    assert_equal 41, played[:count], "one quick pass, then the slow one on every frame to the fourth"
  end

  # A game that does what the interpreter refuses stops with the interpreter's words.
  def test_a_full_list_stops_the_game_in_the_interpreters_words
    program = program_of do
      screen :bitmap
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end

    error = assert_raises(VBlank::IR::ProgramError) { HeadlessRun.new.run(program, frames: 5) }
    assert_match(/list :trail is full \(capacity 2\)/, error.message)
  end

  def test_halt_ends_the_run_where_it_stands
    program = program_of do
      screen :bitmap
      ticks = var :ticks, 0
      game_loop do
        ticks.add! 1
        (ticks >= 3).then { halt }
      end
    end
    run = HeadlessRun.new.run(program, frames: 10)

    assert_equal 3, run[:ticks]
    assert_equal :end, run.moments.last.frame
  end

  # A big table is written as its bytes in base64 rather than as numbers, which a browser runs out
  # of memory reading by the million — and reads back the same at every width, negatives included.
  def test_a_big_table_is_written_as_base64_and_reads_back_the_same
    program = program_of do
      screen :bitmap
      halves = table :halves, (0...300).map { |i| (i * 97) - 15_000 }, width: :half
      words = table :words, (0...300).map { |i| (i * 1_000_003) - 150_000_000 }, width: :word
      bytes = table :bytes, (0...300).map { |i| (i % 256) - 128 }, width: :byte
      at = var :at, 0
      got_half = var :got_half, 0
      got_word = var :got_word, 0
      got_byte = var :got_byte, 0
      game_loop do
        at.set! 299
        got_half.set! halves[at]
        got_word.set! words[at]
        got_byte.set! bytes[at]
      end
    end

    assert_includes JS.new.lower(program), "rg_table_from_base64(Int16Array"
    played = game_player.run(program, frames: 2)
    assert_equal [(299 * 97) - 15_000, (299 * 1_000_003) - 150_000_000, (299 % 256) - 128],
                 [played[:got_half], played[:got_word], played[:got_byte]]
  end

  # Bytes of the console's own machine code only mean something on the console, so a program that
  # can reach them is refused by name, before anything is written.
  def test_raw_machine_code_the_game_reaches_is_refused_by_name
    program = program_of do
      screen :bitmap
      entry { nop }
    end

    error = assert_raises(JS::LoweringError) { JS.new.lower(program) }
    assert_includes error.message, ":raw"
    assert_includes error.message, "browser"
  end

  # ...and in a routine nothing calls they never run, so there is nothing to refuse, as the
  # interpreter refuses them only when it reaches them.
  def test_raw_machine_code_nothing_reaches_is_left_out
    program = program_of do
      screen :bitmap
      func(:unused) { entry { nop } }
      game_loop { clear_screen :black }
    end

    refute_includes JS.new.lower(program), "f_unused"
  end
end
