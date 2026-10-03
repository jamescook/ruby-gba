# frozen_string_literal: true

require "test_helper"

require "stringio"

# A scene's `screen` says which screen the scene draws on, and it is read off the top of the
# scene's block: the screen changes as the scene takes over, before its scenery goes up,
# since changing the kind of screen wipes what was up. A `screen` anywhere else — under a test,
# or in a routine — changes the screen part way through a frame, after the scenery went up, and
# the scene shows nothing.
class TestIRGuardrailScreenInsideScene < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::ScreenInsideScene

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def test_a_screen_under_a_test_in_a_scene_is_flagged
    findings = Check.new.detect(program do
      screen :tiled
      tick = var :tick, 0
      scene(:title) { (tick > 3).then { screen :bitmap } }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :title } }
    end)

    assert_equal 1, findings.length
    assert_equal :error, findings.first.severity
    assert_match(/:title/, findings.first.message)
  end

  def test_a_screen_in_a_routine_is_flagged
    findings = Check.new.detect(program do
      screen :tiled
      func(:switch) { screen :bitmap }
      scene(:title) { call :switch }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :title } }
    end)

    assert_equal 1, findings.length
    assert_match(/:switch/, findings.first.message)
  end

  def test_a_screen_at_the_top_of_a_scene_or_of_the_game_is_left_alone
    findings = Check.new.detect(program do
      screen :tiled
      scene(:title) { screen :bitmap }
      scene(:play) { nil }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :title; when_val 1, :play } }
    end)

    assert_empty findings
  end

  def test_the_build_stops_and_explains
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("SCRN", out: StringIO.new, err: err) do
        screen :tiled
        tick = var :tick, 0
        scene(:title) { (tick > 3).then { screen :bitmap } }
        var :state, 0
        game_loop { case_var(:state) { when_val 0, :title } }
      end
    end

    assert_match(/top of/, err.string, "it says where the screen goes instead")
  end
end
