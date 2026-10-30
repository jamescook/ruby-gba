# frozen_string_literal: true

require "test_helper"
require "differential"
require "midpoint_circle"

# The game whose loop waits for frames under a shaped light, kept once for the console's own
# count of it (test/lowering/gba/vblank/dsl/test_spotlight_show_now_cartridge.rb).
module SpotlightShowNowGames
  include SharedConstants

  # A white room under a shaped light, whose loop opens the light three times a turn, waiting for
  # the next frame after each, and counts its turns and its waits.
  private def loop_waiting_under_a_shaped_light
    waiting = Builder.new
    waiting.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: 10, dark: 100
      loops = var :shape_loops, 2
      light.shape do |row|
        steps = var :shape_steps, 0
        repeat(loops) { steps.add! 1 }
        light.circle(row) + steps - 2
      end
      waited = var :waited, 0
      turns = var :turns, 0
      game_loop do
        turns.add! 1
        repeat(3) do
          light.radius.add! 5
          waited.add! 1
          wait_vblank
        end
        light.radius.set! 10
      end
    end
    waiting.finalize_program
    waiting.program
  end
end

# `light.show_now`: the light as it stands, on the picture being drawn rather than the next one.
# A light's rows are otherwise worked out in the gap before a frame, so a change made during a
# pass shows a picture later, the way a sprite's place does. A game that copies its rows to the
# display while the picture is being drawn — The Minish Cap opening its circle — shows the first
# one on the frame it asks for it, and this is how a game says that.
class TestSpotlightShowNow < Minitest::Test
  include Differential
  include MidpointCircle
  include SpotlightShowNowGames

  OPENS = 5

  # A white room under a light that starts shut and black, whose loop counts its turns and opens
  # the light to 4 on turn OPENS, then 4 more each turn; with +now+ it shows the first at once.
  private def opening_game(now:)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: 0, dark: 100
      turn = var :turn, 0
      game_loop do
        turn.add! 1
        (turn > OPENS).then { light.radius.add! 4 }
        (turn == OPENS).then do
          light.radius.set! 4
          light.show_now if now
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Each row's lit span on every picture: entry n is read at the end of turn n.
  private def pictures(program, frames)
    seen = []
    run = game_player
    run.each_vblank { seen << lit_spans(run.screen) }
    run.run(program, frames: frames)
    seen
  end

  private def shut = Array.new(HEIGHT)

  def test_a_light_shown_now_is_on_the_picture_of_the_turn_that_changed_it
    seen = pictures(opening_game(now: true), OPENS + 3)

    assert_same_spans shut, seen[OPENS - 1], "the turn before"
    assert_same_spans game_circle_spans(120, 80, 4), seen[OPENS], "the turn it opens"
    assert_same_spans game_circle_spans(120, 80, 4), seen[OPENS + 1], "the turn after, drawn from the turn it opened"
    assert_same_spans game_circle_spans(120, 80, 8), seen[OPENS + 2], "and on a picture behind from there"
  end

  def test_without_show_now_the_light_shows_on_the_next_picture
    seen = pictures(opening_game(now: false), OPENS + 2)

    assert_same_spans shut, seen[OPENS], "the turn it opens"
    assert_same_spans game_circle_spans(120, 80, 4), seen[OPENS + 1], "the turn after"
  end

  def test_the_console_and_every_other_backend_show_it_on_the_same_picture
    assert_backends_agree(opening_game(now: true), frames: [OPENS - 1, OPENS, OPENS + 1, OPENS + 2], name: "SHOWNOW")
  end

  # Shown now inside a counted loop, the light's own working out — a loop of its own here — leaves
  # the outer loop's count alone: the loop makes all its passes, and the light it sets after
  # them is the size that count says.
  def test_showing_the_light_now_inside_a_loop_keeps_the_loops_count
    counted = Builder.new
    counted.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: 10, dark: 100
      loops = var :shape_loops, 2
      light.shape do |row|
        steps = var :shape_steps, 0
        repeat(loops) { steps.add! 1 }
        light.circle(row) + steps - 2
      end
      passes = var :passes, 0
      game_loop do
        passes.set! 0
        repeat(3) do
          passes.add! 1
          light.radius.set! passes * 10
          light.show_now
        end
      end
    end
    counted.finalize_program
    seen = pictures(counted.program, 4)

    assert_same_spans game_circle_spans(120, 80, 30), seen[3], "three passes make a radius of 30"
    assert_backends_agree(counted.program, frames: [3, 4], name: "SHOWLOOP")
  end

  # ...and so does the gap between frames, where the same working out runs: a loop that waits for
  # the next frame inside itself makes all its passes. (The console's own count of its turns and
  # waits, read in the emulator, is in
  # test/lowering/gba/vblank/dsl/test_spotlight_show_now_cartridge.rb.)
  def test_a_loop_waiting_for_frames_keeps_its_count_under_a_shaped_light
    assert_backends_agree(loop_waiting_under_a_shaped_light, frames: 2..8, name: "WAITLOOP")
  end

  # A scene that sees through a layer has the light off. The scene after it shows the light now
  # on its first pass, and every backend shows it on the same picture; a scene the light is off
  # in shows nothing however often it asks.
  def test_showing_the_light_now_as_a_scene_takes_turns_with_it
    taking_turns = Builder.new
    taking_turns.instance_eval do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      light = spotlight at: [120, 80], radius: 30, dark: 100
      mode = var :mode, 0
      turn = var :turn, 0
      scene(:title) do
        layer(:water, transparency: 50) { background :pond, tiles: :set, map: ["#" * 32] * 32 }
        light.show_now
      end
      scene(:playing) { light.show_now }
      game_loop do
        turn.add! 1
        (turn == OPENS).then { mode.set! 1 }
        case_var(:mode) { when_val 0, :title; when_val 1, :playing }
      end
    end
    taking_turns.finalize_program

    assert_backends_agree(taking_turns.program, frames: (OPENS - 1..OPENS + 2), name: "SHOWTURNS")
  end
end
