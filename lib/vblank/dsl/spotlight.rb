# frozen_string_literal: true

module VBlank
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
      def initialize(x:, y:, radius:, dark:, builder:)
        @x = x
        @y = y
        @radius = radius
        @dark = dark
        @builder = builder
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

      # GIVE THE LIGHT A SHAPE OF THE GAME'S OWN, a row of the screen at a time. The block is
      # handed the row, 0 at the top, and gives back how far the light reaches either side of
      # its middle on that row — or the row's two edges, `[left, right]`, the columns from left
      # up to (not including) right. The circle is the shape a light has until it is given one.
      #
      #   light.shape { |row| 40 - (row - light.y).abs }               # a diamond
      #   light.shape { |row| light.circle((row - 1).clamp(0, 159)) }  # each row the circle of the row above
      #
      # The rows are worked out in the gap before each frame, from what the game's numbers hold
      # then. A shape works its rows out and does nothing else: it may declare variables of its
      # own and change them, and read the game's numbers and tables, but it cannot change a
      # variable of the game's, read a list or the buttons, call a routine, play a sound or draw.
      # That is what lets the console skip the rows on a frame nothing they read has changed.
      def shape(&block)
        @builder.record_light_shape(self, &block)
        self
      end

      # How far this light's circle reaches either side of its middle on +row+ — the shape the
      # light has until it is given one, for a shape to build on. Up to a radius of 150 it is
      # the midpoint circle the console's own games draw.
      def circle(row) = @builder.light_circle(self, row)

      # SHOW THE LIGHT AS IT STANDS ON THE PICTURE BEING DRAWN, not the next one. A change to the
      # light otherwise shows a picture later, like a sprite's place, because its rows are
      # worked out in the gap before a frame. A game whose own light is handed to the display
      # while the picture is drawn shows a change at once — an iris that opens on the frame it
      # is asked for — and this is how a game copying one says so.
      #
      #   light.radius.set! 4
      #   light.show_now
      #
      # On the console the rows are worked out where this is reached. Early in a pass that is
      # still the gap before the picture, and the whole picture shows them; once the display has
      # started drawing, only the lines it reaches after they are worked out do, so call it
      # early. A light that has not changed costs nothing.
      def show_now
        @builder.show_light_now
        self
      end
    end
  end
end
