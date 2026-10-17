# frozen_string_literal: true

require "test_helper"
require "stringio"

# `estimate: { usually: N }` was read by the cost estimate, which is gone: the build measures
# a game by running it now. A game written while the hint meant something still says it, so
# the hint is taken and set aside, with one warning naming every line that gives one.
class TestIRGuardrailEstimateDoesNothing < Minitest::Test
  # Every verb that took a hint, each with one.
  private def hinted_game
    proc do
      screen :bitmap
      image(:wall, "#" => :white) { "##\n##" }
      body = list :body, capacity: 8, estimate: { usually: 2 }
      pool :spark, x: 0, capacity: 4, estimate: { usually: 1 }
      n = var :n, 3
      game_loop do
        repeat(n, estimate: { most: 4 }) { body.push 1 }
        (n > 0).then(estimate: { usually: 1, in: 60 }) { set! :seen, 1 }
        draw_rect_at 0, 0, 2, n, :white, estimate: { usually: 3 }
        draw_column_at :wall, slice: 0, x: 4, top: 0, height: n, estimate: { usually: 1, in: 60 }
      end
    end
  end

  private def build_warnings(&game)
    err = StringIO.new
    RubyGBA.build("HINTS", out: StringIO.new, err: err, &game)
    err.string
  end

  def test_a_game_that_gives_hints_still_builds_and_is_warned_once
    said = build_warnings(&hinted_game)

    assert_match(/`estimate:`/, said)
    assert_equal 1, said.scan(/has no effect/).size, "once, however many hints there are"
    lines = said.scan(/test_ir_guardrail_estimate_does_nothing\.rb:(\d+)/).flatten.uniq
    assert_equal 6, lines.size, "and it names every line that gives one: #{said}"
  end

  def test_a_game_with_no_hints_is_not_warned
    said = build_warnings do
      screen :bitmap
      list :body, capacity: 8
      game_loop { set! :n, 1 }
    end

    refute_match(/estimate/, said)
  end

  # Whatever a hint said, the game runs the same: a wrong one is not refused any more.
  def test_a_hint_changes_nothing_about_the_run
    plain = Builder.new
    plain.instance_eval do
      body = list :body, capacity: 8
      3.times { |n| body.push n }
      set! :len, body.length
      halt
    end
    hinted = Builder.new
    hinted.instance_eval do
      body = list :body, capacity: 8, estimate: { usualy: 99 }
      3.times { |n| body.push n }
      set! :len, body.length
      halt
    end

    plain.finalize_program
    hinted.finalize_program

    hinted_len = game_player.run(hinted.program)[:len]

    assert_equal 3, hinted_len
    assert_equal game_player.run(plain.program)[:len], hinted_len
  end
end
