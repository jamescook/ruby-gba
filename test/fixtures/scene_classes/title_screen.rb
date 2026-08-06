# frozen_string_literal: true

require "test_helper"

# A whole SCENE as a plain class in its own file — the coarse-grained version of the
# multi-file parts pattern. It takes the build, declares its own presentation in
# initialize (a green marker; declared inside its scene, so it belongs to that scene), and
# exposes `update` as its per-frame entry point. No base class, no magic — the same POROs
# the shmup's parts use, one level up.
module SceneClassFixture
  class TitleScreen
    def initialize(build)
      @build = build
      build.image(:title_dot, "#" => :green) { "########\n" * 8 }
      @dot = build.sprite(:title_dot, at: [20, 40])
    end

    # Drift right while this screen is the active one — a visible marker that its per-frame
    # update ran (and, when this screen isn't active, that it did not).
    def update
      @dot.move :right, by: 2
    end
  end
end
