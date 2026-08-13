# frozen_string_literal: true

module Wolf3D
  # A floor seen from above, two pixels a cell, so a 64x64 level is 128x128 on a 240x160 screen.
  #
  # Every cell is known when the ROM is built, so the whole picture is drawn here in plain Ruby
  # and shipped as one image. Emitting a fill per cell would be four thousand instructions for a
  # picture that never changes.
  #
  # It earns its place beyond looking at: when the first-person view puts you inside a wall,
  # this is what shows the grid the engine thinks it has.
  class MapView
    SCALE = 2
    ORIGIN_X = 56
    ORIGIN_Y = 14

    FLOOR = RubyGBA::Color.rgb(4, 4, 6)
    DOOR = RubyGBA::Color.rgb(31, 26, 6)
    LOCKED = RubyGBA::Color.rgb(31, 12, 22)
    ELEVATOR = RubyGBA::Color.rgb(10, 26, 31)
    PUSHWALL = RubyGBA::Color.rgb(20, 10, 26)
    THING = RubyGBA::Color.rgb(12, 12, 14)
    START = RubyGBA::Color.rgb(10, 31, 10)

    def initialize(build, level)
      @build = build
      @level = level
    end

    def declare
      @build.image :map, width: width, height: height, data: pixels
      self
    end

    def draw
      @build.blit :map, ORIGIN_X, ORIGIN_Y
    end

    def width = @level.width * SCALE
    def height = @level.height * SCALE

    # One colour per cell, then blown up to the scale.
    def pixels
      cells = @level.each_cell.map { |x, y| colour_at(x, y) }
      cells.each_slice(@level.width).flat_map do |row|
        stretched = row.flat_map { |colour| [colour] * SCALE }
        [stretched] * SCALE
      end.flatten
    end

    private

    def colour_at(x, y)
      return START if @level.start&.then { |s| s.x == x && s.y == y }
      return PUSHWALL if @level.pushwall?(x, y)
      return ELEVATOR if @level.elevator?(x, y)
      return LOCKED if @level.locked_door?(x, y)
      return DOOR if @level.door?(x, y)
      return wall_shade(@level.wall_code(x, y)) if @level.solid?(x, y)
      return THING if @level.thing_code(x, y).positive?

      FLOOR
    end

    # Wall codes run from one upward and each is a different texture, so shading by the code
    # makes the rooms of a floor tell themselves apart.
    def wall_shade(code)
      step = (code % 6) * 3
      RubyGBA::Color.rgb(12 + step, 10 + (step / 2), 8)
    end
  end
end
