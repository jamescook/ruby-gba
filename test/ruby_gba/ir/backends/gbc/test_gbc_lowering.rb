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

  private

  def program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.tap { |built| built.console = :gbc }
  end
end
