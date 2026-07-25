# frozen_string_literal: true

module RubyGBA
  # The four (and four diagonal) screen directions, as plain names a game reads in —
  # so you can say "move left" instead of "subtract from x". A direction is a unit
  # step from the player's point of view: +up+ is toward the top of the screen,
  # +down+ toward the bottom, +left+/+right+ as you'd expect. Each maps to a
  # [dx, dy] step of -1, 0, or +1 per axis, which a caller scales by a speed.
  #
  # It's a shared vocabulary, not just a sprite thing: anything that moves or faces a
  # way (a sprite you steer, a snake's heading) can lean on the same names instead of
  # hand-writing the arithmetic.
  module Direction
    # name -> [dx, dy] unit step. Screen coordinates, so "up" decreases y.
    UNIT = {
      up:    [0, -1], down:  [0,  1], left: [-1, 0], right: [1, 0],
      up_left: [-1, -1], up_right: [1, -1], down_left: [-1, 1], down_right: [1, 1]
    }.freeze

    module_function

    # The [dx, dy] unit step for a direction name. An unknown name is almost always
    # a typo — one that would otherwise move nothing — so it's a friendly error.
    def unit(name)
      UNIT[name] ||
        raise(ArgumentError, "unknown direction #{name.inspect} — the directions are #{UNIT.keys.join(', ')}")
    end

    # True if +name+ is a known direction.
    def known?(name)
      UNIT.key?(name)
    end
  end
end
