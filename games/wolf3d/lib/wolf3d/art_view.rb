# frozen_string_literal: true

module Wolf3D
  # A wall and a sprite from the game, drawn at half size so they fit beside the map.
  #
  # Halving takes every other pixel rather than averaging: this is here to show that the bytes
  # decoded correctly, and an average would hide a pixel landing in the wrong place, which is
  # exactly the mistake worth seeing.
  class ArtView
    SIDE = 32 # half of the 64 the game stores

    def initialize(build, palette)
      @build = build
      @palette = palette
      @placed = []
    end

    # +at+ is where it goes; +transparent+ marks the see-through pixels of a sprite.
    def add(name, art, at:)
      @build.image name, width: SIDE, height: SIDE, data: pixels(art), transparent: TRANSPARENT
      @placed << [name, at]
      self
    end

    def draw = @placed.each { |name, (x, y)| @build.blit(name, x, y) }

    # A value no real color can take, so the framework knows which pixels not to draw.
    TRANSPARENT = 0x8000

    private

    def pixels(art)
      (0...SIDE).flat_map do |y|
        (0...SIDE).map do |x|
          index = art[x * 2, y * 2]
          index.nil? ? TRANSPARENT : @palette[index]
        end
      end
    end
  end
end
