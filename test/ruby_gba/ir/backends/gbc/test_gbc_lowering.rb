# frozen_string_literal: true

require "test_helper"

# THE COLOR'S LOWERING, the IR straight to SM83 (GBC::Lowering). Each game here is built by it —
# the cartridge carries its `main`, which the statement path never names — and played as a Color
# cartridge against the interpreter after every pass (GBC::CheckedRun), so a variable that differs
# anywhere fails the test besides what it asserts.
class TestGBCLowering < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  def test_game_of_numbers_alone_is_lowered_straight_to_sm83
    assert GBC::Lowering.makes?(program { var :n, 1 })
    refute GBC::Lowering.makes?(program { clear_screen :blue }), "drawing is not made yet"
  end

  # Every statement of the first slice, in one game: a scene picked by a `case` that changes the
  # scene it reads, a counted loop that stops early, beats, a call picked by a number past the end
  # of its list, a button held, and the sums and tests between them.
  def test_game_plays_as_the_interpreter_plays_it
    game = program do
      var :state, 0
      total = var :total, 0
      which = var :which, 0
      var :beats, 0
      func(:one) { add! :total, 100 }
      func(:two) { add! :total, 1000 }
      scene(:title) { set! :state, 1 }
      scene(:play) do
        repeat(5, stop_when: total > 40) { |i| add! :total, i * 3 }
        call %i[one two], number: which
        add! :which, 1
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        every(3) { add! :beats, 1 }
        held(:a).then { sub! :total, 7 }.else { clamp! :total, -5, 5000 }
      end
    end

    assert GBC.new.build(game).built.code.key?("main"), "built by the lowering, not the statement path"
    run = GBC::CheckedRun.new.hold(:a).run(game, frames: 12)
    assert_equal 4, run[:beats]
    assert_operator run[:which], :>, 2, "the call picked past the end of its list called nothing and went on"
  end

  # Lists of bytes and of words, grown, shrunk from both ends, written into, filled and copied from
  # a table; a table of halves whose length is a power of two, read past its end (it wraps), and one
  # of bytes read past its end (it is held to its last entry). 300 in a byte reads back as 44.
  def test_lists_and_tables_play_as_the_interpreter_plays_them
    game = program do
      steps = table :steps, [3, -2, 300, 7], width: :half, signed: true
      odd = table :odd, [5, 6, 7], width: :byte
      trail = list :trail, capacity: 8, width: :byte
      words = list :words, capacity: 4
      bytes = list :bytes, capacity: 4, width: :byte
      i = var :i, 0
      sum = var :sum, 0
      game_loop do
        trail.push steps[i]
        (trail.length > 5).then { trail.shift }
        bytes.copy_from(odd, at: i % 2, count: 2)
        words.push bytes[1]
        words.push odd[i + 10]
        words.push i
        words.fill 9, from: 2, count: 1
        words[0] = trail.last
        sum.set! sum + words[0] + words[1] + words[2] + trail.first
        3.times { words.pop }
        i.add! 1
      end
    end

    assert GBC.new.build(game).built.code.key?("main"), "built by the lowering, not the statement path"
    run = GBC::CheckedRun.new.run(game, frames: 10)
    assert_equal 5, run.list(:trail).length
  end

  # A number kept over the power going off, and a record saved, loaded back and checked by the game
  # itself: the cartridge's save memory ends as the interpreter's, byte for byte.
  def test_saves_play_as_the_interpreter_plays_them
    game = program do
      best = save_var :best, 5
      score = var :score, 0
      loaded = var :loaded, 0
      files = save_data(:files) { keep score }
      game_loop do
        best.add! 2
        score.add! 3
        (score == 9).then { files[0].save }
        (score == 15).then do
          score.set! 0
          files[0].load
          loaded.set! score
        end
      end
    end

    assert GBC.new.build(game).built.code.key?("main"), "built by the lowering, not the statement path"
    store = SaveImage.new
    run = GBC::CheckedRun.new(save: store).run(game, frames: 40)
    assert_equal 9, run[:loaded]
  end

  # Two timers: a slow one read by its ticks, and a fast one whose ticks call a routine and stop it
  # once enough have gone by — a pass crossing two of its ticks runs its handler twice.
  def test_timers_play_as_the_interpreter_plays_them
    game = program do
      fast_count = var :fast_count, 0
      func(:count_tick) { add! :fast_count, 1 }
      slow = timer :slow, per_second: 7
      fast = timer :fast, per_second: 90
      fast.on_tick do
        call :count_tick
        (fast_count >= 20).then { fast.stop }
      end
      var :seen, 0
      game_loop { set! :seen, slow.ticks }
    end

    assert GBC.new.build(game).built.code.key?("main"), "built by the lowering, not the statement path"
    run = GBC::CheckedRun.new.run(game, frames: 30)
    assert_equal 21, run[:fast_count], "stopped on the 20th tick, the first of a frame's two, and the second still ran"
  end

  private

  def program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.tap { |built| built.console = :gbc }
  end
end
