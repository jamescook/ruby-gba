# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_big_maps"

# A big map on the Advance's cartridge: how many of its cells the cartridge copies into the
# console's grid to put a view up, as its profiler measures them. What a big map shows, on every
# run, is in test/all/vblank/builder/test_big_maps.rb.
class TestBigMapsCartridge < Minitest::Test
  include BigMapsGames

  VIEW_CELLS = 31 * 21
  VIEW_BYTES = VIEW_CELLS * 2

  # A jump straight across, the view's row unchanged: the whole view is filled again in the
  # gap, not walked over a column at a time, which would take far longer than the gap.
  def test_a_jump_across_alone_fills_the_whole_view
    rom = VBlank.build("BIGX", console: :gba, out: nil, err: nil) do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "#" => :floor
      ground = background :ground, tiles: :ground, map: ["#" * 126] * 30
      pass = var :pass, 0
      x = var :view_x, 0
      game_loop do
        pass.add! 1
        x.set! ((pass & 1) * 760)
        ground.scroll_to x, 0
      end
    end
    copied = VBlank::Diagnostics::Profiler.run(rom, frames: 20, picture: false).video_copies
                                           .find { |copy| copy.source.include?(":ground") }
    assert_operator copied.bytes_per_frame, :<=, VIEW_BYTES, "a whole view a frame at most, never 95 columns"
  end

  # --- how much a view costs to put up ---

  # Cells the console copied into the view of background :ground over the 20 frames a profile
  # measures, or 0 when it copied none.
  private def cells_copied(rom)
    copies = VBlank::Diagnostics::Profiler.run(rom, frames: 20, picture: false).video_copies
    copies.find { |copy| copy.source.include?(":ground") }&.copies || 0
  end

  # A scene owning a big room takes over every fourth pass, for one pass. +body+ is what else
  # its body does on that pass.
  private def taking_over_every_fourth_pass(name, &body)
    big = (["#" * 100] * 90).freeze
    VBlank.build(name, console: :gba, out: nil, err: nil) do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "#" => :floor
      pass = var :pass, 0
      var :mode, 0
      scene(:waiting) { nil }
      scene(:playing) do
        ground = background :ground, tiles: :ground, map: { first: big, second: big }
        instance_exec(ground, &body) if body
      end
      game_loop do
        pass.add! 1
        set! :mode, 0
        ((pass & 3) == 0).then { set! :mode, 1 }
        case_var(:mode) do
          when_val 0, :waiting
          when_val 1, :playing
        end
      end
    end
  end

  # A SCENE TAKING OVER FILLS ITS BIG ROOM'S VIEW ONCE, in the five takeovers a profile sees,
  # and once still when it names the first map on that pass. Naming ANOTHER map there is two
  # pictures, each a whole view: the frame the scene takes over on shows its first map, as
  # declared, on every backend, and the frame after shows the map named.
  def test_a_scene_taking_over_fills_the_view_of_its_big_room_once
    assert_equal 5 * VIEW_CELLS, cells_copied(taking_over_every_fourth_pass("BIGT1"))
    assert_equal 5 * VIEW_CELLS, cells_copied(taking_over_every_fourth_pass("BIGT2") { |ground| ground.show_map :first })
    assert_equal 10 * VIEW_CELLS, cells_copied(taking_over_every_fourth_pass("BIGT3") { |ground| ground.show_map :second })
  end

  # A SCENE'S FIRST TAKEOVER, NAMED AT THE END OF THE PASS BEFORE — as a file screen does on START
  # — fills the view once. The gap between that pass and the takeover already counts the new scene
  # as the one running, so its big room's view used to be filled there too, before the scene had put
  # its scenery up at all, and then again as it did.
  # The takeover fills the view round the corner and the gap after it copies the strips between
  # there and where the view is put: one whole view, five columns of 21 cells and three rows of 31.
  def test_a_first_takeover_named_at_the_end_of_the_pass_before_fills_the_view_once
    test = self
    rom = VBlank.build("BIGF1", console: :gba, out: nil, err: nil) { test.named_at_the_end_of_a_pass(self) }
    copies = VBlank::Diagnostics::Profiler.run(rom, frames: 30, settle: 0, picture: false).video_copies
    copied = copies.find { |copy| copy.source.include?(":ground") }&.copies || 0

    assert_equal VIEW_CELLS + (5 * 21) + (3 * 31), copied, "cells copied into the view over the takeover"
  end
end
