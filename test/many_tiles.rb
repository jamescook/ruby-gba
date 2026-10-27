# frozen_string_literal: true

require "test_helper"

# Backgrounds of many different tiles, for the tests of what a console does when a game's tiles
# together are more than it holds at once (test/vblank/builder/test_scene_backgrounds.rb,
# test/vblank/builder/test_background_tile_sets.rb).
module ManyTiles
  # Tiles a row of such a map holds, and so how wide it is.
  ACROSS = 20

  module_function

  # Declare +count+ tiles in +builder+, as images named +prefix+ and a number and a tileset named
  # +prefix+, each one +color+ on black in a pattern no other tile numbered +from+ to +from+ +
  # +count+ has: its number in binary, a pixel a bit, along its first rows. Hands back the map
  # that shows each of them once, ACROSS to a row, keyed by its number in the set.
  def declare(builder, prefix, count, color, from: 0)
    keys = (0...count).to_h do |k|
      name = :"#{prefix}_#{k}"
      bits = from + k
      art = (0...8).map { |row| (0...8).map { |col| bits[(row * 8) + col] == 1 ? "#" : "." }.join }.join("\n")
      builder.image(name, "#" => color, "." => :black) { art }
      [k, name]
    end
    builder.tiles(prefix, keys)
    (0...count).each_slice(ACROSS).map { |row| row + ([nil] * (ACROSS - row.length)) }
  end
end
