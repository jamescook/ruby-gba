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

  BendForm = RubyGBA::IR::Backends::GBA::BendForm

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
  # real shape of the effect, and the one an animated bend has to get right, since a still
  # bend looks the same whichever frame you read it on.
  #
  # It is compared at EQUAL frame counts, where a framebuffer program needs the console run
  # a frame longer (Differential::BOOT_FRAMES). A bending program spends a good part of its
  # first frame getting ready — filling a table of row offsets, or arming an interrupt and
  # answering it — and comes out of that a frame further on than a program that only draws.
  # The sweep below is what establishes the pairing rather than assuming it, which is the
  # point: this is measured, like BOOT_FRAMES itself, and not worked out from first
  # principles.
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

  # THREE layers bending at once, which is as many as there are engines to feed them —
  # each with its own table, its own engine and its own rhythm. Every one of the 38,400
  # pixels, because the way this breaks is subtle: two engines aimed at one scroll register,
  # or a table handed to the wrong layer, still draws a picture that bends.
  def three_bends_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:back_bar, "." => :blue, "#" => :red) { (["##......"] * 8).join("\n") }
      image(:mid_bar, "." => :transparent, "#" => :green) { (["..##...."] * 8).join("\n") }
      image(:front_bar, "." => :transparent, "#" => :white) { (["....##.."] * 8).join("\n") }
      tiles :back_set, "#" => :back_bar
      tiles :mid_set, "#" => :mid_bar
      tiles :front_set, "#" => :front_bar
      back = background :back, tiles: :back_set, map: Array.new(20) { "#" * 30 }
      mid = background :mid, tiles: :mid_set, map: Array.new(20) { "#" * 30 }
      front = background :front, tiles: :front_set, map: Array.new(20) { "#" * 30 }
      back.scroll_each_row { |row| row % 8 }
      mid.scroll_each_row { |row| (row * 2) % 8 }
      front.scroll_each_row { |row| -(row % 8) }
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  def test_three_bending_layers_are_each_fed_by_an_engine
    assert BendForm.copier?(three_bends_program)
    assert_backends_agree(three_bends_program, frames: 4, name: "TRIB")
  end

  # A BEND BESIDE SAMPLED SOUND, on the console. Recorded sound is fed to the sound hardware
  # from a copying engine too, continuously, which is the same standing claim a bend makes —
  # so this is the pair that would fight over one if the engines were handed out carelessly,
  # and the failure would be a silent game or a scrambled picture. Both are checked.
  def test_a_bend_and_sampled_sound_keep_out_of_each_others_way
    program = sounding_program(bends: 1)
    assert BendForm.copier?(program), "one engine is left for the bend"

    rom = assemble_rom(program, name: "SNDB")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.sound?, "the sample still reaches the speaker"
    assert v.red?(0, 0), "...and row 0 sits where it was drawn, unbent"
    assert v.red?(4, 4), "...while row 4 has slid four across"
    refute v.red?(0, 4), "...so the bar that was at the left edge has left it"
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

  # --- which way it is lowered ---
  #
  # A block that is one number can be worked out ahead of the frame, into a table one of
  # the console's copying engines feeds to the display by itself. A block that does more
  # than that has to run where the display asks, which means being interrupted per line.
  # The build picks, and what it picks is worth a great deal — see the cost tests below.

  def test_a_block_that_is_one_number_is_fed_by_the_copier
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    assert BendForm.copier?(program)
    assert_nil BendForm.kept_interrupt_reason(program)
  end

  # A block that sets a variable or calls a routine is a program, and no copier runs a
  # program — it moves numbers. So that one keeps the interrupt, which can run anything.
  def test_a_block_that_does_more_keeps_the_interrupt
    program = bars_program do |water|
      shift = var :shift, 0
      water.scroll_each_row do |row|
        shift.set row % 4
        shift
      end
    end
    refute BendForm.copier?(program)
    assert_match(/does more than work one number out/, BendForm.kept_interrupt_reason(program))
  end

  # Three of the console's four copying engines can be lent out — the fourth is the general
  # copier every fill and upload uses — so a FOURTH bending layer is one more than there is
  # an engine for, and then they all go back on the interrupt. All of them or none: the
  # interrupt costs the whole 228 lines the moment one bend needs it, so feeding the others
  # from tables as well would add work for no saving.
  def test_a_fourth_bending_layer_puts_them_all_back_on_the_interrupt
    refute BendForm.copier?(four_bends_program)
    assert_match(/4 bending layers and 3 copying engines free/,
                 BendForm.kept_interrupt_reason(four_bends_program))
  end

  # ...and a game playing SAMPLED SOUND has one engine, because the sound is fed from an
  # engine too and cannot share. That is worth naming in the reason: nothing about a second
  # bending layer suggests the sound took its engine.
  def test_sampled_sound_leaves_room_for_one_bending_layer
    assert BendForm.copier?(sounding_program(bends: 1))
    refute BendForm.copier?(sounding_program(bends: 2))
    assert_match(/2 bending layers and 1 copying engine free, and this game's sampled sound holds the rest/,
                 BendForm.kept_interrupt_reason(sounding_program(bends: 2)))
  end

  # A program with as many bending layers as asked for, each on its own background.
  def many_bends_program(count)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      count.times do |i|
        bg = background :"layer#{i}", tiles: :stripes, map: Array.new(20) { "#" * 30 }
        bg.scroll_each_row { |row| (row + i) % 8 }
      end
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  def four_bends_program = many_bends_program(4)

  # The same, playing a sample — which is fed from an engine of its own and keeps the pair
  # this framework holds back for sound.
  def sounding_program(bends:)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      bends.times do |i|
        bg = background :"layer#{i}", tiles: :stripes, map: Array.new(20) { "#" * 30 }
        bg.scroll_each_row { |row| (row + i) % 8 }
      end
      sample(:blip, pcm: [30, -30] * 200, rate: 8192).play
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  # The table is filled once a frame, so a program with no frames has nowhere to fill it.
  def test_a_program_with_no_frame_keeps_the_interrupt
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :ts, "#" => :t
      background(:bg, tiles: :ts, map: Array.new(20, "#" * 30)).scroll_each_row { |row| row % 8 }
      halt
    end
    b.emit_pending_functions
    refute BendForm.copier?(b.program)
    assert_match(/never waits for a frame/, BendForm.kept_interrupt_reason(b.program))
  end

  # --- the cost is visible ---

  # Bending is paid per ROW, not per statement, so it is nowhere in the op tree — a reader
  # hunting for where a chunk of their frame went would find nothing. It is priced for the
  # whole frame and named in the report, together with WHICH way it was lowered: the two
  # prices are far enough apart that a reader comparing two games needs to know.
  def test_the_report_names_what_bending_costs
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    verdict = RubyGBA::IR::CostModel.new.bend_verdict(program)
    assert_equal [:water], verdict.layers
    assert_equal :copier, verdict.lowering

    io = StringIO.new
    RubyGBA::IR::CostModel.new.report(program, out: io, color: false)
    assert_match(/bending :water costs/, io.string)
    assert_match(/copier hands each row its offset/, io.string)
  end

  # ...and when it kept the interrupt it says so, and says why — the reader who has seen the
  # other price in another game will otherwise think this one is wrong.
  def test_the_report_says_when_the_interrupt_was_kept_and_why
    verdict = RubyGBA::IR::CostModel.new.bend_verdict(four_bends_program)
    assert_equal :interrupt, verdict.lowering
    assert_operator verdict.feeding, :>, 20, "228 interruptions a frame is the bulk of the cost"

    io = StringIO.new
    RubyGBA::IR::CostModel.new.report(four_bends_program, out: io, color: false)
    assert_match(/interrupted on all 228 of its lines/, io.string)
    assert_match(/could not feed this one: there are 4 bending layers/, io.string)
  end

  # THE WHOLE POINT, as a number: the same picture, worked out ahead of the frame, for a
  # fraction of what being interrupted 228 times costs. Both are measured on the emulator,
  # so this is a real saving and not an arrangement of weights.
  def test_the_copier_costs_a_fraction_of_the_interrupt
    pure = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    copied = RubyGBA::IR::CostModel.new.bend_verdict(pure)
    interrupted = RubyGBA::IR::CostModel.new.bend_verdict(four_bends_program)

    assert_operator copied.cost * 2, :<, interrupted.cost,
                    "expected the copier to be worth more than half, got " \
                    "#{copied.cost.round(1)} against #{interrupted.cost.round(1)}"
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
    assert_equal 0, RubyGBA::IR::CostModel.new.bend_verdict(cheap).offsets,
                 "a number written in the program costs nothing to read"
    assert_operator RubyGBA::IR::CostModel.new.bend_verdict(dear).offsets, :>, 0,
                    "arithmetic in the block is paid on every row of every frame"
  end
end
