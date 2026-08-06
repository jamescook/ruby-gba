# frozen_string_literal: true

require "test_helper"

# The second scene, in its own file: a cyan marker that drifts while this screen is active.
# Same shape as TitleScreen — a plain object that takes the build, declares its presentation
# in initialize, and exposes `update`.
module SceneClassFixture
  class PlayScreen
    def initialize(build)
      @build = build
      build.image(:play_dot, "#" => :cyan) { "########\n" * 8 }
      @dot = build.sprite(:play_dot, at: [20, 40])
    end

    def update
      @dot.move :right, by: 2
    end
  end
end
