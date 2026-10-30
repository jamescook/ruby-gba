# frozen_string_literal: true

require "test_helper"

# Backgrounds of many different tiles, or of many lists of colours, for the tests of what a console
# does when a game's tiles or colours together are more than it holds at once
# (test/all/vblank/builder/test_scene_backgrounds.rb, test/all/vblank/builder/test_background_tile_sets.rb).
module ManyTiles
  # Tiles a row of such a map holds, and so how wide it is.
  ACROSS = 20

  # An 8×8 tile drawn in all four places of its list: a quarter of the tile each.
  QUARTERS = Array.new(64) { |i| 1 + ((i % 8) / 4) + (2 * ((i / 8) / 4)) }.freeze

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

  # Declare in +builder+ a tile for each of +lists+ — four colours each, place 0 see-through — drawn
  # by place in all four of its list's places (QUARTERS), for the tests of what a console does when
  # a game draws from more lists of colours than it holds at once. The lists and images are named
  # +prefix+ and a number, the tileset +prefix+. Hands back a row of a map showing each tile once.
  def declare_listed(builder, prefix, lists)
    lists.each_with_index do |list, n|
      builder.colors(:"#{prefix}_list#{n}", list)
      builder.image(:"#{prefix}_tile#{n}", width: 8, height: 8, colors: :"#{prefix}_list#{n}", places: QUARTERS)
    end
    builder.tiles(prefix, lists.each_index.to_h { |n| [n.to_s, :"#{prefix}_tile#{n}"] })
    lists.each_index.map(&:to_s).join
  end
end
