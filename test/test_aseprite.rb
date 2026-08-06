# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
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
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")
  # The committed fixtures. A JSON+PNG export and a native .aseprite binary, both a 4-frame
  # sheet of red, green, blue, white. The JSON one is tagged walk = 0..1 / blink = 2..3;
  # the binary one is tagged walk = 0..1 / idle = 2..3. And a real Aseprite file (the bird).
  FIXTURE = File.expand_path("fixtures/aseprite/hero.json", __dir__)
  BINARY = File.expand_path("fixtures/aseprite/hero_rgba.aseprite", __dir__)
  BIRD = File.expand_path("../examples/assets/bird.aseprite", __dir__)

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
    assert_equal [0, 0, 8, 8, 120], doc.frames[0].deconstruct
    assert_equal [%i[idle], [0], [1]].flatten, [doc.tags.map(&:name), doc.tags.map(&:from), doc.tags.map(&:to)].flatten
  end

  def test_the_parser_reads_the_array_layout
    doc = Aseprite.parse(ARRAY_JSON)
    assert_equal 2, doc.frames.length
    assert_equal [4, 2, 8, 8, 80], doc.frames[0].deconstruct, "an array-layout frame keeps its rect and duration"
    assert_equal :run, doc.tags.first.name
  end

  def test_the_parser_rejects_non_aseprite_json
    err = assert_raises(ArgumentError) { Aseprite.parse('{"hello":1}') }
    assert_match(/not an Aseprite/, err.message)
  end

  # --- the sprite: import the fixture, play named animations (both backends) ---

  def game(mode:, run:, play: nil, file: FIXTURE)
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
      hero = sprite :hero, at: [40, 40], from_aseprite: file
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

  def spot(program) = Reference.new.run(program).screen.pixel(44, 44)
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

  # --- the native binary .aseprite, read directly (no export step) ---

  def test_the_binary_parser_reads_frames_tags_and_colors
    sprite = Aseprite.load_binary(File.binread(BINARY))
    assert_equal 4, sprite.frames.length
    assert_equal %i[walk idle], sprite.tags.map(&:name)
    assert_equal [0, 1], [sprite.tags[0].from, sprite.tags[0].to]
    assert_includes sprite.frames[0].data.uniq, c(255, 0, 0), "frame 0 decodes to red"
  end

  def test_the_binary_parser_composites_the_real_bird
    sprite = Aseprite.load_binary(File.binread(BIRD))
    assert_equal 6, sprite.frames.length, "the bird has six frames"
    assert_equal [64, 64], [sprite.frames[0].width, sprite.frames[0].height]
    marker = RubyGBA::Image::TRANSPARENT
    lit = sprite.frames[0].data.count { |px| px != marker }
    assert_operator lit, :>, 100, "the seven layers composite into a bird's worth of lit pixels"
  end

  def test_rejecting_bytes_that_are_not_an_aseprite_file
    err = assert_raises(ArgumentError) { Aseprite.load_binary(("nope" * 40).b) }
    assert_match(/not an .aseprite/, err.message)
  end

  def test_a_native_aseprite_file_imports_and_plays
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 3, file: BINARY)), "native: walk's first frame (red)"
    assert_equal c(0, 255, 0), spot(game(mode: :bitmap, run: 9, file: BINARY)), "native: walk animates (green)"
    assert_equal c(0, 0, 255), spot(game(mode: :bitmap, run: 3, file: BINARY, play: :idle)), "native: play(:idle) (blue)"
  end

  def test_a_native_aseprite_file_on_a_hardware_sprite
    assert_equal c(255, 255, 255), spot(game(mode: :tiled, run: 9, file: BINARY, play: :idle)), "tiled native: idle's second frame (white)"
  end

  def test_on_console_a_native_aseprite_file_composites
    rom = ROM.assemble(GBA.new.lower(game(mode: :tiled, run: 3, file: BINARY, play: :idle)),
                       title: "ASEBIN", code: "BABN", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, c(0, 0, 255)),
           "a native .aseprite file: play(:idle)'s blue should composite on the console, got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  # --- per-frame timing: a frame held longer plays longer ---

  # Build a tiny 8x8 RGBA .aseprite (one layer, no tags — a single clip) with one solid-color
  # frame per [duration_ms, [r, g, b]] entry, write it to a temp file, and return the path so
  # from_aseprite: can read it. The Tempfile is held on @tmp so it outlives the test body.
  def timed_aseprite(specs)
    frames = specs.each_with_index.map do |(duration_ms, rgb), i|
      chunks = (i.zero? ? [ase_layer] : []) + [ase_cel(rgb + [255])]
      ase_frame(chunks, duration_ms)
    end
    header = ("\x00" * 128).b
    header[4, 2] = [0xA5E0].pack("v")
    header[6, 2] = [specs.length].pack("v")
    header[8, 2] = [8].pack("v")   # width
    header[10, 2] = [8].pack("v")  # height
    header[12, 2] = [32].pack("v") # RGBA
    header[14, 4] = [1].pack("V")  # flags: opacity valid
    bytes = (header + frames.join).b
    bytes[0, 4] = [bytes.bytesize].pack("V")

    file = Tempfile.new(["timed", ".aseprite"])
    file.binmode
    file.write(bytes)
    file.flush
    (@tmp ||= []) << file
    file.path
  end

  def ase_chunk(type, data) = [6 + data.bytesize].pack("V") + [type].pack("v") + data
  def ase_layer = ase_chunk(0x2004, [1, 0, 0, 0, 0, 0].pack("v6") + [255].pack("C") + ("\x00" * 3) + [1].pack("v") + "L")

  def ase_cel(rgba)
    head = [0].pack("v") + [0, 0].pack("s<2") + [255].pack("C") + [0].pack("v") + [0].pack("s<") + ("\x00" * 5) + [8, 8].pack("v2")
    ase_chunk(0x2005, head + (rgba.pack("C4") * 64))
  end

  def ase_frame(chunks, duration_ms)
    body = chunks.join
    [16 + body.bytesize].pack("V") + [0xF1FA].pack("v") + [0].pack("v") + [duration_ms].pack("v") + ("\x00" * 2) + [chunks.length].pack("V") + body
  end

  # Frame 0 (red) is held 200ms = 12 game frames; frame 1 (green) 100ms = 6. So the clip
  # runs red for 12, green for 6, then loops. A uniform rate would take the SLOWEST frame
  # (12) for both, keeping green up through frame 23 — so green gone by frame 20 proves each
  # frame keeps its own hold.
  def test_a_frame_held_longer_plays_longer
    path = timed_aseprite([[200, [255, 0, 0]], [100, [0, 255, 0]]])
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 6, file: path)), "red holds through frame 6"
    assert_equal c(0, 255, 0), spot(game(mode: :bitmap, run: 15, file: path)), "green is up mid-way through its own hold"
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 20, file: path)),
                 "green's own 6-frame hold ended and the clip looped back to red (a uniform rate would still show green)"
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
