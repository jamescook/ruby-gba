# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The native .aseprite loader composites layers: it skips hidden layers, blends a
# partly-transparent layer over what is below it, and reads grayscale as well as RGBA. A
# blend mode other than Normal, or a tilemap layer, is a friendly error (flatten it in
# Aseprite first). These build tiny .aseprite files in memory to exercise each case,
# without committing binary fixtures.
class TestAsepriteLayers < Minitest::Test
  Aseprite = RubyGBA::Aseprite
  Color = RubyGBA::Color

  # --- a minimal in-memory .aseprite builder (RGBA or grayscale, solid-color cels) ---

  def chunk(type, data) = [6 + data.bytesize].pack("V") + [type].pack("v") + data

  def layer_chunk(visible:, blend:, opacity:)
    data = +""
    data << [visible ? 1 : 0].pack("v")  # flags: bit 0 = visible
    data << [0, 0].pack("vv")            # layer type (normal), child level
    data << [0, 0].pack("vv")            # deprecated default w, h
    data << [blend].pack("v")            # blend mode (0 = normal)
    data << [opacity].pack("C")          # opacity
    data << ("\x00" * 3) << [1].pack("v") << "L"
    chunk(0x2004, data)
  end

  def cel_chunk(width, height, layer:, color:, opacity: 255, type: 0)
    data = +""
    data << [layer].pack("v") << [0, 0].pack("s<s<") << [opacity].pack("C")
    data << [type].pack("v") << [0].pack("s<") << ("\x00" * 5)
    data << [width, height].pack("vv")
    data << (color.pack("C*") * (width * height))
    chunk(0x2005, data)
  end

  def frame_chunk(chunks)
    body = chunks.join
    header = [16 + body.bytesize].pack("V") + [0xF1FA].pack("v") + [0].pack("v") +
             [100].pack("v") + ("\x00" * 2) + [chunks.length].pack("V")
    header + body
  end

  # +layers+: [{ visible:, blend:, opacity: }]. +cels+: [{ layer:, color:, opacity:, type: }],
  # painted in order onto one frame. +depth+ 32 = RGBA (color is [r,g,b,a]), 16 = grayscale
  # (color is [value, alpha]).
  def build_ase(cels, layers:, depth: 32, w: 2, h: 2)
    header = ("\x00" * 128).b
    header[4, 2] = [0xA5E0].pack("v")
    header[6, 2] = [1].pack("v") # one frame
    header[8, 2] = [w].pack("v")
    header[10, 2] = [h].pack("v")
    header[12, 2] = [depth].pack("v")
    header[14, 4] = [1].pack("V")
    frame = frame_chunk(layers.map { |l| layer_chunk(**l) } + cels.map { |c| cel_chunk(w, h, **c) })
    file = (header + frame).b
    file[0, 4] = [file.bytesize].pack("V")
    file
  end

  def first_pixel(bytes) = Aseprite.load_binary(bytes).frames.first.data.first

  # --- the cases ---

  def test_a_hidden_layer_does_not_draw
    px = first_pixel(build_ase(
      [{ layer: 0, color: [255, 0, 0, 255] }, { layer: 1, color: [0, 255, 0, 255] }],
      layers: [{ visible: true, blend: 0, opacity: 255 }, { visible: false, blend: 0, opacity: 255 }]))
    assert_equal Color.rgb8(255, 0, 0), px, "the visible red layer shows; the hidden green one does not"
  end

  def test_a_partly_transparent_layer_blends_over_what_is_below
    px = first_pixel(build_ase(
      [{ layer: 0, color: [255, 0, 0, 255] }, { layer: 1, color: [0, 0, 255, 255] }],
      layers: [{ visible: true, blend: 0, opacity: 255 }, { visible: true, blend: 0, opacity: 128 }]))
    refute_equal Color.rgb8(0, 0, 255), px, "a 50% blue over red is not pure blue"
    refute_equal Color.rgb8(255, 0, 0), px, "and not pure red"
    assert_operator(px & 0x1F, :>, 0, "keeps some red from below")
    assert_operator((px >> 10) & 0x1F, :>, 0, "picks up some blue from on top")
  end

  def test_a_cel_below_full_opacity_blends_too
    px = first_pixel(build_ase(
      [{ layer: 0, color: [255, 0, 0, 255] }, { layer: 1, color: [0, 0, 255, 255], opacity: 100 }],
      layers: [{ visible: true, blend: 0, opacity: 255 }, { visible: true, blend: 0, opacity: 255 }]))
    refute_equal Color.rgb8(0, 0, 255), px, "the cel's own opacity blends it over the red below"
    assert_operator(px & 0x1F, :>, 0, "keeps some red")
  end

  def test_grayscale_frames_decode
    px = first_pixel(build_ase(
      [{ layer: 0, color: [200, 255] }], # grayscale: value 200, opaque
      layers: [{ visible: true, blend: 0, opacity: 255 }], depth: 16))
    assert_equal Color.rgb8(200, 200, 200), px, "a grayscale value decodes to a gray console color"
  end

  def test_a_non_normal_blend_mode_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Aseprite.load_binary(build_ase([{ layer: 0, color: [255, 0, 0, 255] }],
                                     layers: [{ visible: true, blend: 3, opacity: 255 }]))
    end
    assert_match(/blend mode/, err.message)
  end

  def test_a_tilemap_cel_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Aseprite.load_binary(build_ase([{ layer: 0, color: [0, 0, 0, 0], type: 3 }],
                                     layers: [{ visible: true, blend: 0, opacity: 255 }]))
    end
    assert_match(/tilemap/, err.message)
  end
end
