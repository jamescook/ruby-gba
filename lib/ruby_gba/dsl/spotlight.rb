# frozen_string_literal: true

module RubyGBA
  module DSL
    # A handle to the game's light: a circle the picture is drawn as it is inside, with
    # everything outside it darkened. `spotlight at: [120, 80], radius: 40` hands one back.
    # See Builder#spotlight.
    #
    #   light = spotlight at: [120, 80], radius: 40, dark: 75
    #   light.move_to hero.x + 8, hero.y + 8   # the lantern goes where the hero does
    #   light.radius.approach! 24, 1           # ...and it shrinks
    #   light.dark.set! 0                      # nothing darkened: the light is out
    #
    # Each of the four is a {Value} the game reads and changes like any variable, and the
    # picture shows what they hold at the end of the frame — it is worked out again in the
    # gap before every frame, so moving the light costs a write and nothing else.
    class Spotlight
      # Built by Builder#spotlight, which declares the four and what the picture makes of them.
      def initialize(x:, y:, radius:, dark:)
        @x = x
        @y = y
        @radius = radius
        @dark = dark
      end

      # Where the middle of the light is, in screen pixels: across from the left edge, and
      # down from the top. The screen's, not a background's, so a light kept on the hero is
      # moved to where the hero's sprite is.
      attr_reader :x, :y

      # How far the light reaches from its middle, in pixels. 0 lights nothing at all.
      attr_reader :radius

      # How dark the picture is outside the light, 0 (as drawn) to 100 (black).
      attr_reader :dark

      # Put the middle of the light at (+x+, +y+). Either may be worked out as the game runs.
      def move_to(x, y)
        @x.set! x
        @y.set! y
        self
      end
    end
  end
end
