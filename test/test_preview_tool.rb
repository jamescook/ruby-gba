# frozen_string_literal: true

require "test_helper"

require "zlib"
require_relative "../tools/preview"

# The preview tool (tools/preview.rb): runs a program on the interpreter, captures its
# frames, and encodes each as a PNG in a self-contained HTML page you can watch. These
# pin the two things that could silently produce a broken page — the frame capture and
# the PNG bytes — plus the CLI's example lookup.
class TestPreviewTool < Minitest::Test

  # A tiny program that paints the screen red and loops, so a capture has real frames.
  def red_loop
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        clear_screen :red
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_capture_grabs_the_requested_number_of_frames
    shots = Preview.capture(red_loop, frames: 4)
    assert_equal 4, shots.size, "capture should stop once it has the frames asked for"
    first = shots.first
    assert_equal 240, first[:width]
    assert_equal 160, first[:height]
    # A frame is presented at the top of each pass, so the very first one is shown
    # before the program has drawn anything. The red arrives from the pass after it.
    assert_equal Color.resolve(:red), shots.last[:pixels][0],
                 "the captured frame shows what the program drew"
  end

  def test_capture_can_be_driven_by_held_buttons
    # A red block that only moves right while right is held. Held, it slides across the
    # screen; left alone it stays at the left edge.
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      x = var :x, 4
      game_loop do
        wait_vblank
        held(:right).then { x.add 2 }
        clear_screen :black
        draw_rect_at x, 10, 4, 4, :red
      end
    end
    b.emit_pending_functions
    prog = b.program

    red = Color.resolve(:red)
    at_x16 = ->(shots) { shots.any? { |f| f[:pixels][(11 * 240) + 16] == red } }
    assert at_x16.call(Preview.capture(prog, frames: 10) { [:right] }), "holding right slides the block to x16"
    refute at_x16.call(Preview.capture(prog, frames: 10)), "left alone the block never reaches x16"
  end

  def test_png_encodes_the_pixels_as_truecolor
    frame = { width: 2, height: 2, pixels: [0x001F, 0x03E0, 0x7C00, 0x7FFF] } # red, green, blue, white
    png = Preview.png(frame)
    assert_equal Preview::PNG_SIGNATURE, png.byteslice(0, 8), "starts with the PNG signature"

    raw = Zlib::Inflate.inflate(idat(png))
    expected = [
      0, 255, 0, 0, 0, 255, 0,        # row 0: filter byte, red, green
      0, 0, 0, 255, 255, 255, 255,    # row 1: filter byte, blue, white
    ].pack("C*")
    assert_equal expected, raw, "each 15-bit color expands to 8-bit RGB, one filter byte per row"
  end

  def test_html_inlines_one_png_per_frame_and_a_canvas
    shots = Preview.capture(red_loop, frames: 3)
    page = Preview.html(shots, title: "Test <run>")
    assert_includes page, "<canvas"
    assert_equal 3, page.scan("data:image/png;base64,").size, "one inlined PNG per frame"
    assert_includes page, "Test &lt;run&gt;", "the title is html-escaped"
  end

  def test_fragment_omits_the_document_wrapper
    page = Preview.html(Preview.capture(red_loop, frames: 1), title: "x", fragment: true)
    refute_includes page, "<!doctype", "a fragment is body content only, for embedding"
    assert_includes page, "<canvas"
  end

  def test_load_example_resolves_a_module_with_a_program
    assert_respond_to Preview.load_example("parallax"), :program
    assert_raises(ArgumentError) { Preview.load_example("no_such_example") }
  end

  # The bytes of a PNG's single IDAT (image data) chunk, walking the chunk list past
  # the 8-byte signature: each chunk is length(4) + type(4) + data + crc(4).
  def idat(png)
    pos = 8
    while pos < png.bytesize
      len = png.byteslice(pos, 4).unpack1("N")
      type = png.byteslice(pos + 4, 4)
      return png.byteslice(pos + 8, len) if type == "IDAT"

      pos += 12 + len
    end
    flunk "no IDAT chunk in the PNG"
  end
end
