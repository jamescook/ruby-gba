# frozen_string_literal: true

# A game "part" in its own file — a plain object handed the builder, the multi-file
# pattern the cost-tree-by-source grouping is for. Its draws are recorded from THIS
# file, so every node it builds carries left_wall.rb as its source.
module CostParts
  class LeftWall
    def initialize(build)
      @build = build
    end

    def draw
      @build.fill_rect 0, 0, 10, 100, :red
      @build.fill_rect 0, 100, 10, 60, :blue
    end
  end
end
