# frozen_string_literal: true

require "test_helper"

# HOW MANY BYTES A GAME COPIES INTO VIDEO MEMORY WHILE IT RUNS, by what copied them.
#
# A game copies pictures into the memory the screen is drawn from in three ways after it boots:
# tiles it paints from a list, a whole map handed to a background, and a sprite kept to one
# frame at a time getting its next frame. Each is a copy in the gap between frames, and each
# costs time a game would otherwise have — so the profile counts them, from the console, on
# the frames it measured.
class TestVideoCopies < Minitest::Test
  def build(&block) = RubyGBA.build("VCOPY", out: nil, err: nil, &block)

  def copies(rom) = RubyGBA::Diagnostics::Profiler.run(rom, frames: 20, picture: false).video_copies

  # A 104-tile run, painted and copied on every frame — what a box typing a letter a frame does.
  def painting_every_frame
    build do
      screen :tiled
      colors :ink, %i[transparent white]
      canvas = list :canvas, capacity: 3328, width: :byte
      repeat(3328) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 104, colors: :ink
      background :front, tiles: :box, map: (0...4).map { |r| (1..26).map { |c| (r * 26) + c } }
      game_loop { box.changed }
    end
  end

  def test_a_run_painted_every_frame_copies_its_whole_list_every_frame
    found = copies(painting_every_frame).find { |copy| copy.source.include?(":box") }

    refute_nil found, "the run's copy is named"
    assert_equal 3328, found.bytes_per_frame
  end

  def test_a_game_that_copies_nothing_says_nothing
    rom = build do
      screen :tiled
      image(:red_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :red_art
      background :field, tiles: :set, map: ["##"]
      game_loop {}
    end

    assert_empty copies(rom)
  end

  # Two rooms, handed to the background turn about: every frame is a whole map copied.
  def test_a_map_handed_over_every_frame_is_counted_under_its_background
    rom = build do
      screen :tiled
      image(:red_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :red_art, "." => :red_art
      rooms = background :rooms, tiles: :set, map: { hall: ["#."], cave: [".#"] }
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        rooms.show_map frame & 1
      end
    end
    found = copies(rom).find { |copy| copy.source.include?(":rooms") }

    refute_nil found
    assert_operator found.bytes_per_frame, :>, 0
  end

  # Two areas, walked between turn about: every frame brings a whole set of tiles in, and the
  # set's copy is counted apart from the map's.
  def test_an_area_walked_into_every_frame_is_counted_apart_from_its_map
    rom = build do
      screen :tiled
      image(:red_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:green_art, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :red_art
      tiles :clearing, "#" => :green_art
      rooms = background :rooms, tiles: { shrine: :shrine, clearing: :clearing },
                                 map: { shrine: { hall: ["##"] }, clearing: { glade: ["##"] } }
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        rooms.show_map frame & 1
      end
    end
    found = copies(rom).find { |copy| copy.source.include?("set of tiles") }

    refute_nil found, "the set's copy is named"
    assert_includes found.source, ":rooms"
    assert_operator found.bytes_per_frame, :>, 0
  end

  # A view walked across a map bigger than the console's grid, a cell a frame: each frame
  # brings one column of 21 cells in, two bytes a cell, rather than the whole view.
  def test_a_big_map_walked_a_cell_a_frame_copies_a_column_a_frame
    rom = build do
      screen :tiled
      image(:red_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :red_art
      field = background :field, tiles: :set, map: ["#" * 120] * 30
      x = var :x, 0
      game_loop do
        x.add! 8
        field.scroll_to x, 0
      end
    end
    found = copies(rom).find { |copy| copy.source.include?(":field") }

    refute_nil found, "the strip copy is named"
    assert_operator found.bytes_per_frame, :>=, 42
    assert_operator found.bytes_per_frame, :<, 31 * 21 * 2, "not the whole view every frame"
  end

  INKS = (1..15).map { |i| RubyGBA::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # A 64x64 picture in fifteen inks, its pixels drawn at random from its own seed, so no 8x8
  # part of it is the same as a part of any other one made here — a pattern would repeat, and
  # the build stores a repeated part once, which would let all seventeen fit.
  def frame_art(number)
    dice = Random.new(number)
    Array.new(64 * 64) { INKS[dice.rand(15)] }
  end

  # Seventeen 64x64 frames are more than sprite memory holds at once, so the sprite keeps one
  # frame there and is sent the next as it changes — on every frame, at one picture a frame.
  def test_a_sprite_kept_to_one_frame_is_counted_under_its_name
    art = method(:frame_art)
    rom = build do
      screen :tiled
      names = (0...17).map do |n|
        image(:"f#{n}", width: 64, height: 64, data: art.call(n))
        :"f#{n}"
      end
      sprite :giant, at: [0, 0], frames: names, rate: 1
      game_loop {}
    end
    found = copies(rom).find { |copy| copy.source.include?(":giant") }

    refute_nil found, "the sprite's frames are named"
    assert_in_delta 2048, found.bytes_per_frame, 2048 * 0.1, "one 64x64 frame, a byte per two pixels, each frame"
  end

  def test_the_json_profile_carries_the_copies
    result = RubyGBA::Diagnostics::Profiler.run(painting_every_frame, frames: 20, picture: false)
    copy = result.to_h.fetch(:video_copies).first

    assert_equal 3328, copy.fetch(:bytes_per_frame)
    assert_match(/:box/, copy.fetch(:source))
  end
end
