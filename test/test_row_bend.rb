# frozen_string_literal: true

require "test_helper"
require_relative "differential"

# Bending a background row by row — `background.scroll_each_row`.
#
# The console builds the screen one line at a time and re-reads where each layer sits for
# every line, so a program can give each row its own sideways offset and the picture bends.
# The interpreter has no lines and no interrupts: it paints the window row by row and reads
# the same offset per row. These assert the two produce the SAME picture, because the whole
# point of the feature is that the effect is a property of the program and not of the
# machine.
class TestRowBend < Minitest::Test
  include Differential

  # A background of narrow vertical bars. Vertical edges are what a sideways shift moves,
  # so where a row's bars land IS its offset, read straight off the screen.
  def bars_program(&bend)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :bar, "." => :transparent, "#" => :red do
        <<~ART
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
        ART
      end
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      instance_exec(water, &bend) if bend
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  # A screen row as a picture: "R" where a bar covers it, "." where it does not. The bars
  # are 2 pixels of every 8, so this reads as the row's own offset directly.
  def row_picture(interpreter, y, width = 12)
    (0...width).map { |x| interpreter.screen.pixel(x, y).to_i.zero? ? "." : "R" }.join
  end

  # --- what the block means ---

  # A sawtooth: each row one pixel further across than the row above. Reading the rows as
  # pictures says both things that can go wrong at once — the amount a row moved, and
  # which row moved by it.
  def test_each_row_is_offset_by_what_the_block_returns
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    i = Reference.new.run(program)
    assert_equal "RR......RR..", row_picture(i, 0), "row 0 is not offset — the bars sit as drawn"
    assert_equal "R......RR...", row_picture(i, 1), "row 1 slid one pixel left"
    assert_equal "......RR....", row_picture(i, 2)
    assert_equal ".RR......RR.", row_picture(i, 7), "row 7 slid seven"
    assert_equal "RR......RR..", row_picture(i, 8), "the sawtooth restarts every 8 rows"
  end

  # No bend at all leaves every row where it was drawn — the feature costs nothing when
  # it is not used, and this is the baseline the tests above are measured against.
  def test_without_a_bend_every_row_sits_the_same
    i = Reference.new.run(bars_program)
    pictures = (0...16).map { |y| row_picture(i, y) }
    assert_equal ["RR......RR.."] * 16, pictures
  end

  # A bend on top of a scroll: the row offset is measured FROM wherever the background is
  # scrolled to, so a background can travel and ripple at once. Scrolled 3 and bent by 2,
  # a row sits at 5 — not at 2, which is what replacing the scroll rather than adding to
  # it would give.
  def test_a_row_offset_is_added_to_the_backgrounds_own_scroll
    scrolled_only = bars_program { |water| water.scroll_to 3, 0 }
    both = bars_program do |water|
      water.scroll_to 3, 0
      water.scroll_each_row { |_row| 2 }
    end
    bend_only = bars_program { |water| water.scroll_each_row { |_row| 2 } }

    scrolled = Reference.new.run(scrolled_only)
    combined = Reference.new.run(both)
    bent = Reference.new.run(bend_only)

    refute_equal row_picture(scrolled, 0), row_picture(combined, 0),
                 "the bend moved the row on top of the scroll"
    refute_equal row_picture(bent, 0), row_picture(combined, 0),
                 "...and the scroll still counts — the bend did not replace it"
    # Scrolled 3 and bent 2 is a row sitting at 5, which is the same picture as scrolling
    # 5 and not bending at all.
    assert_equal row_picture(Reference.new.run(bars_program { |w| w.scroll_to 5, 0 }), 0),
                 row_picture(combined, 0), "the two offsets add"
  end

  # --- the console and the interpreter draw the same picture ---

  # Every one of the 38,400 pixels, for a bend that varies down the screen. This is the
  # assertion that settles the hardware detail the feature turns on: the console writes a
  # row's offset in the gap after the PREVIOUS line, so the framework has to write row
  # N+1's offset while line N is finishing, and wrap that round at the bottom of the frame
  # so the very top row is bent like the rest. Get either wrong and rows shift by one here.
  def test_the_console_and_the_interpreter_bend_the_same_rows
    assert_backends_agree(bars_program { |water| water.scroll_each_row { |row| row % 8 } },
                          frames: 4, name: "BEND")
  end

  # A travelling ripple: a sine table read at an index the program moves every frame — the
  # real shape of the effect, and a different lowering path (a ROM table read inside the
  # per-line handler) from the arithmetic above.
  #
  # It is compared at EQUAL frame counts, where a framebuffer program needs the console run
  # a frame longer (Differential::BOOT_FRAMES). A bend is not drawn by the program: the
  # console writes a frame's row offsets from the end of the previous frame through to the
  # bottom of this one, so its picture is already a frame further on than a draw the loop
  # made — which cancels the boot frames exactly. The sweep below is what establishes that
  # rather than assuming it.
  def ripple_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :bar, "." => :transparent, "#" => :red do
        <<~ART
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
          ##......
        ART
      end
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      ripple = table :ripple, (0...64).map { |i| (Math.sin(i * 2 * Math::PI / 64) * 3).round }
      phase = var :phase, 0
      water.scroll_each_row { |row| ripple[(row - phase) % 64] }
      game_loop { phase.add 1 }
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_travelling_ripple_agrees_across_backends
    assert_backends_agree(ripple_program, frames: 4, console_frames: 4, name: "RIPL")
  end

  # The same, frame after frame. One frame agreeing could be a coincidence of where the
  # wave happened to sit; four consecutive frames agreeing is the two backends animating
  # together. This is also what proves the interpreter repaints a bending background every
  # frame — before it did, its picture froze after the first and only this test noticed.
  def test_the_ripple_agrees_frame_after_frame
    (2..5).each do |f|
      assert_backends_agree(ripple_program, frames: f, console_frames: f, name: "RIP#{f}")
    end
  end

  # A bend and a scroll together, across backends: the console applies the scroll once a
  # frame at the frame boundary and the row offset per line, and those two writes go to
  # the same register — so this is where they could fight.
  def test_a_bend_over_a_scrolled_background_agrees_across_backends
    program = bars_program do |water|
      water.scroll_by 5, 0
      water.scroll_each_row { |row| row % 4 }
    end
    assert_backends_agree(program, frames: 4, name: "BSCR")
  end

  # --- more than one layer bending ---

  # Two layers, each with its own bend, going opposite ways. Working one row's offset out
  # needs the accumulator the row number is sitting in, so the second layer would read a
  # clobbered row unless every bend is told the row before any offset is worked out.
  def two_bends_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:back_bar, "." => :blue, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:front_bar, "." => :transparent, "#" => :white) { (["....##.."] * 8).join("\n") }
      tiles :back_set, "#" => :back_bar
      tiles :front_set, "#" => :front_bar
      back = background :back, tiles: :back_set, map: Array.new(20) { "#" * 30 }
      front = background :front, tiles: :front_set, map: Array.new(20) { "#" * 30 }
      back.scroll_each_row { |row| row % 8 }
      front.scroll_each_row { |row| -(row % 8) }
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  def test_each_layer_bends_by_its_own_amount
    i = Reference.new.run(two_bends_program)
    red = ->(y) { (0...16).select { |x| i.screen.pixel(x, y) == Color::PRESETS[:red] } }
    white = ->(y) { (0...16).select { |x| i.screen.pixel(x, y) == Color::PRESETS[:white] } }

    assert_equal [0, 1, 8, 9], red.call(0), "row 0 is unbent on both layers"
    assert_equal [4, 5, 12, 13], white.call(0)
    # By row 4 the back layer has slid 4 left and the front 4 right — opposite ways, which
    # a single shared row offset could not produce.
    assert_equal [4, 5, 12, 13], red.call(4)
    assert_equal [8, 9], white.call(4)
  end

  def test_two_bending_layers_agree_across_backends
    assert_backends_agree(two_bends_program, frames: 4, name: "TWOB")
  end

  # --- guardrails ---

  # A bitmap screen has no background layer to bend — its picture is pixels the program
  # drew. Saying so is a friendly error, not a silently still screen.
  def test_bending_a_bitmap_screen_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :ts, "#" => :t
        bg = background :bg, tiles: :ts, map: Array.new(20, "#" * 30)
        bg.scroll_each_row { |row| row }
      end
    end
    assert_match(/screen :tiled/, err.message)
    assert_match(/scroll_each_row/, err.message)
  end

  def test_scroll_each_row_without_a_block_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :ts, "#" => :t
        background(:bg, tiles: :ts, map: Array.new(20, "#" * 30)).scroll_each_row
      end
    end
    assert_match(/needs a block/, err.message)
  end

  # --- the cost is visible ---

  # Bending is paid per LINE, not per statement, so it is nowhere in the op tree — a
  # reader hunting for where a sixth of their frame went would find nothing. It is priced
  # for the whole frame and named in the report.
  def test_the_report_names_what_bending_costs
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    verdict = RubyGBA::IR::CostModel.new.bend_verdict(program)
    assert_equal [:water], verdict[:layers]
    assert_operator verdict[:interrupts], :>, 20, "228 interruptions a frame is the bulk of the cost"

    io = StringIO.new
    RubyGBA::IR::CostModel.new.report(program, out: io, color: false)
    assert_match(/bending :water costs/, io.string)
    assert_match(/interrupted on all 228 of its lines/, io.string)
  end

  # A program that does not bend pays nothing and says nothing.
  def test_a_program_that_does_not_bend_has_no_bend_cost
    program = bars_program
    assert_nil RubyGBA::IR::CostModel.new.bend_verdict(program)

    io = StringIO.new
    RubyGBA::IR::CostModel.new.report(program, out: io, color: false)
    refute_match(/bending/, io.string)
  end

  # What the block works out is charged too, per visible row — so a dear expression there
  # reads as dear rather than hiding behind the fixed interrupt cost.
  def test_the_blocks_own_work_is_charged_per_visible_row
    cheap = bars_program { |water| water.scroll_each_row { |_row| 3 } }
    dear = bars_program { |water| water.scroll_each_row { |row| (row * row) % 8 } }
    assert_equal 0, RubyGBA::IR::CostModel.new.bend_verdict(cheap)[:offsets],
                 "a number written in the program costs nothing to read"
    assert_operator RubyGBA::IR::CostModel.new.bend_verdict(dear)[:offsets], :>, 0,
                    "arithmetic in the block is paid on every row of every frame"
  end
end
