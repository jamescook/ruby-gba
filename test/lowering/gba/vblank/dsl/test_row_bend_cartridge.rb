# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_row_bend"

# Bending a background row by row on the Advance's cartridge: which way the build lowers a bend
# (one of the console's copying engines, or an interrupt on every line), what each way costs
# measured on the running cartridge, and the bent rows read back in the emulator. What a bend
# draws on every run is in test/all/vblank/dsl/test_row_bend.rb.
class TestRowBendCartridge < Minitest::Test
  include RowBendGames

  BendForm = VBlank::IR::Backends::GBA::BendForm

  # A BLOCK THAT COUNTS is asked once for every row, once a frame, on the console too: it works
  # the rows out in the gap between frames and nowhere else.
  def test_a_block_is_asked_once_for_every_row_each_frame
    rom = assemble_rom(counting_bend_program, name: "BCOUNT")
    v = assert_emulator_loads_rom(rom, frames: 12, vars: rom.var_addresses)

    assert_operator v.var(:passes), :>, 3, "the console should have played a few passes"
    assert_equal 160 * v.var(:passes), v.var(:asked), "the console: 160 a pass"
  end

  # --- more than one layer bending ---

  # A BEND BESIDE SAMPLED SOUND, on the console. Recorded sound is fed to the sound hardware
  # from a copying engine too, continuously, which is the same standing claim a bend makes —
  # so this is the pair that would fight over one if the engines were handed out carelessly,
  # and the failure would be a silent game or a scrambled picture. Both are checked.
  def test_a_bend_and_sampled_sound_keep_out_of_each_others_way
    program = sounding_program(bends: 1)
    assert BendForm.fed_by_dma?(program), "one engine is left for the bend"

    rom = assemble_rom(program, name: "SNDB")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.sound?, "the sample still reaches the speaker"
    assert v.red?(0, 0), "...and row 0 sits where it was drawn, unbent"
    assert v.red?(4, 4), "...while row 4 has slid four across"
    refute v.red?(0, 4), "...so the bar that was at the left edge has left it"
  end

  # --- which way it is lowered ---
  #
  # The rows are worked out at the frame boundary either way, into a table. What the build
  # picks is who moves a row out of that table and into the display's register: one of the
  # console's copying engines, for nothing at all, or an interrupt on every line. It picks
  # the engine whenever there is one free, and that is worth a great deal — see the cost
  # tests below.

  def test_a_bend_is_fed_by_the_copier
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }
    assert BendForm.fed_by_dma?(program)
    assert_nil BendForm.kept_interrupt_reason(program)
  end

  # WHAT IS IN THE BLOCK DOES NOT DECIDE THIS. A block that sets a variable or calls a
  # routine is a program, and no copier runs a program — but nothing asks it to, because
  # the block runs in the frame and only its answer is handed over.
  def test_a_block_that_does_more_is_fed_by_the_copier_too
    program = bars_program do |water|
      shift = var :shift, 0
      water.scroll_each_row do |row|
        shift.set! row % 4
        shift
      end
    end
    assert BendForm.fed_by_dma?(program)
    assert_nil BendForm.kept_interrupt_reason(program)
  end

  # Three of the console's four copying engines can be lent out — the fourth is the general
  # copier every fill and upload uses — so a FOURTH bending layer is one more than there is
  # an engine for, and then they all go back on the interrupt. All of them or none: the
  # interrupt costs the whole 228 lines the moment one bend needs it, so feeding the others
  # from tables as well would add work for no saving.
  def test_a_fourth_bending_layer_puts_them_all_back_on_the_interrupt
    refute BendForm.fed_by_dma?(four_bends_program)
    assert_match(/4 bending layers and 3 copying engines free/,
                 BendForm.kept_interrupt_reason(four_bends_program))
  end

  # ...and a game playing SAMPLED SOUND has one engine, because the sound is fed from an
  # engine too and cannot share. That is worth naming in the reason: nothing about a second
  # bending layer suggests the sound took its engine.
  def test_sampled_sound_leaves_room_for_one_bending_layer
    assert BendForm.fed_by_dma?(sounding_program(bends: 1))
    refute BendForm.fed_by_dma?(sounding_program(bends: 2))
    assert_match(/2 bending layers and 1 copying engine free, and this game's sampled sound holds the rest/,
                 BendForm.kept_interrupt_reason(sounding_program(bends: 2)))
  end

  # A program with as many bending layers as asked for, each on its own background.
  private def many_bends_program(count)
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
    b.finalize_program
    b.program
  end

  private def four_bends_program = many_bends_program(4)

  # The same two fixtures as cartridges that can be RUN, for the measured comparison. Built
  # through the DSL rather than assembled from a program, because a profile needs the record
  # the build makes — where every routine ended up cannot be recovered from the bytes.
  private def bars_rom(&bend)
    VBlank.build("BEND", console: :gba, code: "BEND", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      instance_exec(water, &bend) if bend
      game_loop { }
    end
  end

  private def four_bends_rom
    VBlank.build("BND4", console: :gba, code: "BND4", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      4.times do |i|
        bg = background :"layer#{i}", tiles: :stripes, map: Array.new(20) { "#" * 30 }
        bg.scroll_each_row { |row| (row + i) % 8 }
      end
      game_loop { }
    end
  end

  # The same, playing a sample — which is fed from an engine of its own and keeps the pair
  # this framework holds back for sound.
  private def sounding_program(bends:)
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
    b.finalize_program
    b.program
  end

  # The rows are worked out once a frame, so a program with no frames has no moment to work
  # them out in — and then the handler runs the block itself, line by line, which is what
  # every bend did before there was a table.
  def test_a_program_with_no_frame_keeps_the_interrupt
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :ts, "#" => :t
      background(:bg, tiles: :ts, map: Array.new(20, "#" * 30)).scroll_each_row { |row| row % 8 }
      halt
    end
    b.finalize_program
    refute BendForm.fed_by_dma?(b.program)
    refute BendForm.rows_precomputed?(b.program)
    assert_match(/never waits for a frame/, BendForm.kept_interrupt_reason(b.program))
  end

  # --- the cost is visible ---

  # WHICH WAY A BEND WAS LOWERED is a decision the build makes, and the two are far enough
  # apart in what they cost that it is worth being able to ask. One bend rides a copying
  # engine, which feeds the display with the CPU untouched.
  def test_one_bend_rides_a_copying_engine
    program = bars_program { |water| water.scroll_each_row { |row| row % 8 } }

    assert BendForm.fed_by_dma?(program), "one bend has an engine to spare"
  end

  # ...and a fourth is one more than there are engines, so the game is interrupted on every
  # line of the display instead. The build says why, in words.
  def test_a_fourth_bend_keeps_the_interrupt_and_says_why
    refute BendForm.fed_by_dma?(four_bends_program)
    assert_match(/4 bending layers/, BendForm.kept_interrupt_reason(four_bends_program).to_s)
  end

  # THE WHOLE POINT, as a number: the same picture, worked out ahead of the frame, for a
  # fraction of what being interrupted 228 times costs. MEASURED — the program is built and
  # run, and the instructions it really executes each frame are counted. This used to compare
  # two numbers the estimate made up, which is exactly the claim it was least able to make.
  def test_the_copier_costs_a_fraction_of_the_interrupt
    copied = instructions_a_frame(bars_rom { |water| water.scroll_each_row { |row| row % 8 } })
    interrupted = instructions_a_frame(four_bends_rom)

    assert_operator copied * 2, :<, interrupted,
                    "expected the copier to be worth more than half, got " \
                    "#{copied.round} against #{interrupted.round} instructions a frame"
  end

  private def instructions_a_frame(rom)
    VBlank::Diagnostics::Profiler.run(rom, frames: 20, picture: false).samples_per_frame
  end
end
