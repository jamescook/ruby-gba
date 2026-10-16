# frozen_string_literal: true

require "test_helper"

require "png_reading"
require RubyGBA.root.join("tools/preview").to_s

# The preview tool (tools/preview.rb): runs a program on the interpreter, captures its
# frames, and puts each as a PNG in a self-contained HTML page you can watch. These
# pin the two things that could silently produce a broken page — the frame capture and
# the pictures in the page — plus the CLI's example lookup.
class TestPreviewTool < Minitest::Test
  runs_on :reference, :native

  include PNGReading

  # A tiny program that paints the screen red and loops, so a capture has real frames.
  private def red_loop
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        clear_screen :red
      end
    end
    b.finalize_program
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
        held(:right).then { x.add! 2 }
        clear_screen :black
        draw_rect_at x, 10, 4, 4, :red
      end
    end
    b.finalize_program
    prog = b.program

    red = Color.resolve(:red)
    at_x16 = ->(shots) { shots.any? { |f| f[:pixels][(11 * 240) + 16] == red } }
    assert at_x16.call(Preview.capture(prog, frames: 10) { [:right] }), "holding right slides the block to x16"
    refute at_x16.call(Preview.capture(prog, frames: 10)), "left alone the block never reaches x16"
  end

  # The pictures in the page are the frames that were captured: the last one, taken back out
  # of the page and read by the PNG format's own rules, is the red screen the program drew —
  # 160 rows, each a byte saying it is stored as it stands and then 240 red pixels. (How a
  # picture is written is the library's, and is tested there.)
  def test_the_page_holds_each_frame_as_a_picture_of_what_was_drawn
    page = Preview.html(Preview.capture(red_loop, frames: 3), title: "x")
    last = page.scan(%r{data:image/png;base64,([A-Za-z0-9+/=]+)}).flatten.last.unpack1("m0")

    assert_equal ([0] + ([255, 0, 0] * 240)) * 160, png_rows(last), "the whole of the last frame is red"
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
end
