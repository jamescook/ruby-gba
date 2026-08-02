# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# `sprite ..., from_aseprite: "hero.json"` imports a sprite the way a pixel artist
# authored it in Aseprite: it reads the JSON export for each frame's rectangle and each
# NAMED animation (frameTag), slices the frames out of the PNG, and exposes each tag as
# an animation the game plays on demand — hero.play(:walk) / hero.play(:blink). The
# frames' durations set the speed. This is the metadata-driven complement to the blind
# grid slice of frames_from: / facing_from:.
class TestAseprite < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Aseprite = RubyGBA::Aseprite
  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")
  # The committed fixture: a 4-frame sheet (red, green, blue, white) with two tags —
  # walk = frames 0..1 (red, green), blink = frames 2..3 (blue, white).
  FIXTURE = File.expand_path("fixtures/aseprite/hero.json", __dir__)

  # --- the parser, on inline JSON (both export layouts) ---

  HASH_JSON = <<~JSON
    { "frames": {
        "a 0.ase": { "frame": { "x": 0, "y": 0, "w": 8, "h": 8 }, "duration": 120 },
        "a 1.ase": { "frame": { "x": 8, "y": 0, "w": 8, "h": 8 }, "duration": 120 } },
      "meta": { "image": "a.png",
        "frameTags": [ { "name": "idle", "from": 0, "to": 1 } ] } }
  JSON

  ARRAY_JSON = <<~JSON
    { "frames": [
        { "filename": "a 0", "frame": { "x": 4, "y": 2, "w": 8, "h": 8 }, "duration": 80 },
        { "filename": "a 1", "frame": { "x": 12, "y": 2, "w": 8, "h": 8 }, "duration": 80 } ],
      "meta": { "image": "a.png", "frameTags": [ { "name": "run", "from": 0, "to": 1 } ] } }
  JSON

  def test_the_parser_reads_the_hash_layout
    doc = Aseprite.parse(HASH_JSON)
    assert_equal "a.png", doc.image
    assert_equal 2, doc.frames.length
    assert_equal [0, 0, 8, 8, 120], doc.frames[0].to_a
    assert_equal [%i[idle], [0], [1]].flatten, [doc.tags.map(&:name), doc.tags.map(&:from), doc.tags.map(&:to)].flatten
  end

  def test_the_parser_reads_the_array_layout
    doc = Aseprite.parse(ARRAY_JSON)
    assert_equal 2, doc.frames.length
    assert_equal [4, 2, 8, 8, 80], doc.frames[0].to_a, "an array-layout frame keeps its rect and duration"
    assert_equal :run, doc.tags.first.name
  end

  def test_the_parser_rejects_non_aseprite_json
    err = assert_raises(ArgumentError) { Aseprite.parse('{"hello":1}') }
    assert_match(/not an Aseprite/, err.message)
  end

  # --- the sprite: import the fixture, play named animations (both backends) ---

  def game(mode:, run:, play: nil)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :black) { SOLID8 }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :black
      end
      hero = sprite :hero, at: [40, 40], from_aseprite: FIXTURE
      hero.play(play) if play # switch clip at setup; it holds while the loop animates it
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add 1
        (f >= run).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def spot(program) = Ruby.new.run(program).screen.pixel(44, 44)
  def c(r, g, b) = Color.rgb8(r, g, b)

  def test_the_default_animation_is_the_first_tag_and_it_loops
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 3)), "walk starts on its first frame (red)"
    assert_equal c(0, 255, 0), spot(game(mode: :bitmap, run: 9)), "a few frames on, walk is on its second frame (green)"
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 15)), "walk loops back to its first frame"
  end

  def test_playing_a_named_animation_switches_the_frames
    assert_equal c(0, 0, 255),     spot(game(mode: :bitmap, run: 3, play: :blink)), "blink's first frame (blue)"
    assert_equal c(255, 255, 255), spot(game(mode: :bitmap, run: 9, play: :blink)), "blink's second frame (white)"
  end

  def test_a_hardware_sprite_imports_and_plays_the_same_way
    assert_equal c(255, 0, 0),   spot(game(mode: :tiled, run: 3)), "tiled: walk, red"
    assert_equal c(0, 0, 255),   spot(game(mode: :tiled, run: 3, play: :blink)), "tiled: blink, blue"
  end

  # --- real hardware: the imported, played animation composites on the console ---

  def test_on_console_a_played_animation_composites
    rom = ROM.assemble(GBA.new.lower(game(mode: :tiled, run: 3, play: :blink)),
                       title: "ASEPRIT", code: "BASE", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, c(0, 0, 255)),
           "blink's first frame (blue) should composite on the console, got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  # --- friendly errors ---

  def test_playing_an_unknown_animation_is_a_friendly_error
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        hero = sprite :hero, at: [0, 0], from_aseprite: FIXTURE
        hero.play(:sprint)
      end
    end
    assert_match(/no animation :sprint/, err.message)
  end

  def test_from_aseprite_with_another_pose_source_is_a_friendly_error
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        sprite :hero, at: [0, 0], from_aseprite: FIXTURE, frames: %i[a b], rate: 4
      end
    end
    assert_match(/both from_aseprite: and frames:/, err.message)
  end

  def test_play_on_a_plain_sprite_is_a_friendly_error
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        image(:dot, "#" => :red) { SOLID8 }
        sprite(:dot, at: [0, 0]).play(:walk)
      end
    end
    assert_match(/no named animations/, err.message)
  end
end
