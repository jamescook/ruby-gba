# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/ir/test_layer_allocation"

# A stack on the Advance's cartridge: the limit its lowering is loud about when a picture needs
# more levels than the console stacks, and the build report that says what each layer became.
# What every run draws from a stack is in test/all/vblank/ir/test_layer_allocation.rb.
class TestLayerAllocationCartridge < Minitest::Test
  include LayerAllocationGames

  # --- the limit, spoken in the author's own names ---

  def test_a_picture_deeper_than_the_console_stacks_is_refused
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/needs 5 levels/, error.message)
    assert_match(/stacks 4/, error.message)
  end

  # The refusal has to name the layer that caused it, not a hardware register. It also
  # has to name the RIGHT cause: here it is the sprites behind everything, not the count
  # of backgrounds.
  def test_the_refusal_names_the_layer_that_cost_the_level
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/:ghosts/, error.message)
    assert_match(/behind every background/, error.message)
    refute_match(/BG[0-3]/, error.message)
  end

  def test_the_refusal_shows_the_stack_that_was_declared
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/:ghosts, :l1, :l2, :l3, :l4/, error.message)
  end

  # --- the report ---

  def test_the_report_says_what_each_layer_became
    rom = VBlank.build("STACKED", console: :gba, code: "BSTK", maker: "01", out: nil, err: nil) do
      screen :tiled
      image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layers :sky, :actors, :ui

      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      layer(:actors) { sprite :guy, at: [10, 10] }
      layer(:ui) { draw_text "HI", 8, 8, :white }
      game_loop { nil }
    end

    out = StringIO.new
    VBlank::Diagnostics::BuildReport.render(rom, out: out)
    report = out.string

    assert_match(/the stack, back to front/, report)
    assert_match(/:sky\s+background :bg/, report)
    assert_match(/:actors\s+1 sprite/, report)
    assert_match(/:ui\s+2 sprites/, report)
    assert_match(/1 of 4 levels used, 3 free/, report)
  end

  def test_the_report_says_nothing_about_a_stack_a_game_never_declared
    rom = VBlank.build("PLAIN", console: :gba, code: "BPLN", maker: "01", out: nil, err: nil) do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end

    out = StringIO.new
    VBlank::Diagnostics::BuildReport.render(rom, out: out)

    refute_match(/the stack/, out.string)
  end
end
