# frozen_string_literal: true

# The second part, in its own file — so its draws carry right_wall.rb as their source
# and the cost tree can tell its work apart from the left wall's.
module CostParts
  class RightWall
    def initialize(build)
      @build = build
    end

    def draw
      @build.fill_rect 230, 0, 10, 100, :green
      @build.fill_rect 230, 100, 10, 60, :white
    end
  end
end
