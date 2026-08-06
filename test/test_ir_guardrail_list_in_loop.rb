# frozen_string_literal: true

require "test_helper"

require "stringio"

# A one-time-setup footgun, sibling to the seed-in-loop guardrail: `list` DECLARES a
# collection, set up once. Written inside a per-frame context (the game loop, a scene,
# a repeat/every timer) the declaration re-creates the list empty every frame, so
# pushes vanish and its length never grows. Caught on the IR as a friendly warning.
# Reading/changing a list in the loop is normal and not flagged; only the declaration.
class TestIRGuardrailListInLoop < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::ListInLoop.new])
  end

  def findings_for(program)
    validator.run(program, autofix: false).findings
  end

  def test_a_list_declared_in_the_game_loop_is_flagged
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank, list_new(:bullets, 8), halt),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    assert findings.first.warning?, "a list-in-loop is advisory (the ROM still builds), not fatal"
    assert_match(/bullets/, findings.first.message)
    assert_match(/game loop/i, findings.first.message)
  end

  def test_a_list_declared_in_a_scene_is_flagged_and_names_the_scene
    prog = program(
      screen(:bitmap),
      set(:state, int(0)),
      func(:_scene_play, list_new(:bodies, 16)),
      loop_(wait_vblank, case_(:state, [[0, :_scene_play]])),
    )
    assert_match(/scene :play/i, findings_for(prog).first.message)
  end

  # A list set up once, in setup, then used in the loop — the correct shape.
  def test_a_top_level_list_is_not_flagged
    prog = program(
      screen(:bitmap),
      list_new(:bullets, 8),
      loop_(wait_vblank, list_push(:bullets, int(1)), halt),
    )
    assert_empty findings_for(prog)
  end

  # Pushing to / dropping from a list every frame is normal — only the DECLARATION is
  # one-time setup, so list ops in the loop are left alone.
  def test_list_ops_in_the_loop_are_not_flagged
    prog = program(
      screen(:bitmap),
      list_new(:bullets, 8),
      loop_(wait_vblank, list_push(:bullets, int(1)), list_drop(:bullets, from: :front), halt),
    )
    assert_empty findings_for(prog)
  end

  def test_a_list_in_a_one_shot_after_timer_is_not_flagged
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank, after(:__t, 1, list_new(:scratch, 4)), halt),
    )
    assert_empty findings_for(prog)
  end

  # A list created inside a condition is a deliberate reset, not an unconditional
  # every-frame re-create — left alone.
  def test_a_conditionally_created_list_is_not_flagged
    prog = program(
      screen(:bitmap),
      set(:state, int(0)),
      func(:_scene_play, if_(pressed(:a), list_new(:scratch, 4))),
      loop_(wait_vblank, case_(:state, [[0, :_scene_play]])),
    )
    assert_empty findings_for(prog)
  end

  # End to end through the DSL: declaring a list inside the loop warns on the err
  # stream, but the build still succeeds (advisory, not fatal).
  def test_the_build_warns_but_succeeds_when_declaring_a_list_inside_the_loop
    err = StringIO.new
    RubyGBA.build("LIST", code: "BLST", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      game_loop do
        wait_vblank
        list :bullets, capacity: 8
      end
    end
    assert_match(/bullets/, err.string)
    assert_match(/every frame/i, err.string)
  end
end
