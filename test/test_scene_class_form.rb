# frozen_string_literal: true

require "test_helper"

require_relative "fixtures/scene_classes/title_screen"
require_relative "fixtures/scene_classes/play_screen"

# A scene can be a plain class in its own file — the coarse-grained form of the multi-file
# parts pattern. Each screen (TitleScreen, PlayScreen — separate files) takes the build,
# declares its presentation in initialize, and exposes `update`. You wire them with the
# ordinary verbs: construct each INSIDE its `scene` block (so its sprites belong to that
# scene) and dispatch with case_var. No base class, no registrar, no magic — this test
# proves only the active screen's presentation shows and only its update runs.
class TestSceneClassForm < Minitest::Test

  GREEN = Color.resolve(:green) # TitleScreen's marker
  CYAN = Color.resolve(:cyan)   # PlayScreen's marker

  def program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      var :state, 0
      scene :title do
        screen_obj = SceneClassFixture::TitleScreen.new(self)
        screen_obj.update
      end
      scene :play do
        screen_obj = SceneClassFixture::PlayScreen.new(self)
        screen_obj.update
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions
    b.program
  end

  # The leftmost x where a color appears in the marker's row band, or nil if absent.
  def first_x_of(screen, color)
    (40..47).each { |y| (0...240).each { |x| return x if screen.pixel(x, y) == color } }
    nil
  end

  # While :title is active, only TitleScreen's marker is on screen, and it has drifted
  # right from its start (x=20) — proof its own file's update ran and PlayScreen's did not.
  def test_only_the_active_scene_class_presents_and_updates
    title = Reference.new.run(program, max_steps: 400).screen
    tx = first_x_of(title, GREEN)
    refute_nil tx, "the title screen's marker is on screen while :title is active"
    assert_operator tx, :>, 25, "the title screen's own update moved its marker right"
    assert_nil first_x_of(title, CYAN), "the play screen's marker is hidden while :title is active"
  end

  # Switching state switches which scene class runs: on :play only PlayScreen's marker
  # shows and moves; the title screen's is gone and stayed put.
  def test_switching_state_switches_the_active_scene_class
    play = Reference.new.run(mutate_to_play, max_steps: 400).screen
    px = first_x_of(play, CYAN)
    refute_nil px, "the play screen's marker is on screen while :play is active"
    assert_operator px, :>, 25, "the play screen's own update moved its marker right"
    assert_nil first_x_of(play, GREEN), "the title screen's marker is hidden while :play is active"
  end

  # The same program but starting in :play (state = 1).
  def mutate_to_play
    b = Builder.new
    b.instance_eval do
      screen :tiled
      var :state, 1
      scene :title do
        SceneClassFixture::TitleScreen.new(self).update
      end
      scene :play do
        SceneClassFixture::PlayScreen.new(self).update
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions
    b.program
  end
end
