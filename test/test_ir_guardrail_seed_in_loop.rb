# frozen_string_literal: true

require "test_helper"

require "stringio"

# A one-time-setup footgun: `seed` written inside a per-frame context (the game
# loop, a scene, a repeat/every timer) re-seeds every frame, freezing the random
# stream so every draw returns the same value. Caught on the IR before any ROM is
# built: a friendly warning naming the verb and the fix. A churn (roll/rand/
# randomize) belongs in the loop, and a deliberate edge-gated re-seed is fine, so
# neither is flagged.
class TestIRGuardrailSeedInLoop < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails
  RNG = RubyGBA::Builder::Randomness::RNG_STATE

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::SeedInLoop.new])
  end

  def findings_for(program)
    validator.run(program, autofix: false).findings
  end

  # A seed written straight into the game loop re-runs every frame — flagged.
  def test_a_seed_in_the_game_loop_is_flagged
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank, set(RNG, int(42)), halt),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    finding = findings.first
    assert finding.warning?, "a seed-in-loop is advisory (the ROM still builds), not fatal"
    assert_match(/seed/i, finding.message)
    assert_match(/game loop/i, finding.message)
    assert_match(/randomize/i, finding.message, "the fix points at randomize for stirring")
  end

  # The real-world shape: a seed inside a scene func (dispatched every frame by
  # case_var) — flagged, and the message names the scene.
  def test_a_seed_inside_a_scene_is_flagged_and_names_the_scene
    prog = program(
      screen(:bitmap),
      set(:state, int(0)),
      func(:_scene_play, set(RNG, int(7))),
      loop_(wait_vblank, case_(:state, [[0, :_scene_play]])),
    )
    findings = findings_for(prog)
    assert_equal 1, findings.size
    assert_match(/scene :play/i, findings.first.message)
  end

  # Churning the stream every frame (roll/rand/randomize) is exactly how you keep it
  # moving — it reads the state to advance it, so it is NOT a re-seed and not flagged.
  def test_churning_the_stream_in_the_loop_is_not_flagged
    churn = binop(:+, binop(:*, var_ref(RNG), int(1_664_525)), int(1_013_904_223))
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank, set(RNG, churn), halt),
    )
    assert_empty findings_for(prog)
  end

  # A deliberate re-seed gated by an input edge (seed from the player's reaction
  # time) is a normal pattern — the seed isn't an unconditional per-frame statement,
  # so it's left alone.
  def test_an_edge_gated_reseed_is_not_flagged
    prog = program(
      screen(:bitmap),
      func(:_scene_title, if_(pressed(:start), set(RNG, var_ref(:wait_frames)))),
      loop_(wait_vblank, case_(:state, [[0, :_scene_title]])),
    )
    assert_empty findings_for(prog)
  end

  # A seed in setup — before the loop, run once — is correct and not flagged.
  def test_a_seed_at_the_top_level_is_not_flagged
    prog = program(
      screen(:bitmap),
      set(RNG, int(42)),
      loop_(wait_vblank, halt),
    )
    assert_empty findings_for(prog)
  end

  # `after(n)` runs its body exactly once, so a seed there runs once — not a footgun.
  def test_a_seed_in_a_one_shot_after_timer_is_not_flagged
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank, after(:__t, 30, set(RNG, int(9))), halt),
    )
    assert_empty findings_for(prog)
  end

  # End to end through the DSL: seeding inside a scene warns on the err stream, but
  # the build still succeeds (advisory, not fatal).
  def test_the_build_warns_but_succeeds_when_seeding_inside_a_scene
    err = StringIO.new
    RubyGBA.build("SEED", code: "BSED", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      var :state, 0
      scene :play do
        seed 42
        roll :x, 0..9
      end
      game_loop do
        wait_vblank
        case_var(:state) { when_val 0, :play }
      end
    end
    assert_match(/seed/i, err.string)
    assert_match(/every frame/i, err.string)
  end
end
