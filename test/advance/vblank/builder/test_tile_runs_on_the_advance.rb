# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_tile_runs.rb whose games show a painted background over another background,
# or beside one, which a Game Boy Color's one background layer cannot, so they play on the
# Advance's runs alone.
class TestTileRunsOnTheAdvance < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  # A red backdrop behind a two-tile run, side by side at the top left. +body+ runs every
  # pass with the list, the run's handle and a frame counter.
  private def game(&body)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :floor, "#" => :red_tile
      background :back, tiles: :floor, map: ["##"]
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 2, colors: :ink
      background :front, tiles: :box, map: [[1, 2]]
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        instance_exec(canvas, box, frame, &body)
      end
    end
    b.finalize_program
    b.program
  end

  private def pixel(prog, frames, x, y) = game_player.run(prog, frames: frames).screen.pixel(x, y)

  # One dialogue box shown in two scenes. The second scene has a floor of its own declared
  # first, so its tiles go in ahead of the box's and the box lands somewhere else in video
  # memory there — which is the case one copy to one place cannot serve. A pixel painted in
  # each scene has to show in that scene, and survive the trip to the other one.
  private def shared_box_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 2, colors: :ink
      state = var :state, 0
      frame = var :frame, 0
      scene(:house) do
        background :house_box, tiles: :box, map: [[1, 2]]
        (frame == 2).then { canvas[0] = 0x01; box.changed }
        (frame == 5).then { state.set! 1 }
      end
      scene(:shop) do
        tiles :floor, "#" => :red_tile
        background :floor, tiles: :floor, map: ["####"]
        background :shop_box, tiles: :box, map: [[1, 2]]
        (frame == 8).then { canvas[32] = 0x01; box.changed }
        (frame == 11).then { state.set! 0 }
      end
      game_loop do
        frame.add! 1
        case_var(:state) { when_val 0, :house; when_val 1, :shop }
      end
    end
    b.finalize_program
    b.program
  end

  def test_pixels_written_into_the_list_show_on_the_frame_after_changed
    prog = game do |canvas, box, frame|
      (frame == 3).then do
        canvas[0] = 0x01 # the top-left pixel of tile 1 is place 1, white
        box.changed
      end
    end

    assert_equal RED, pixel(prog, 3, 0, 0), "on the frame it was written, the run still shows what it did"
    assert_equal WHITE, pixel(prog, 4, 0, 0), "on the next frame the list shows"
    assert_equal RED, pixel(prog, 4, 1, 0), "the pixel beside it is place 0, see-through"
  end

  def test_a_write_the_game_never_announces_does_not_show
    prog = game { |canvas, _box, frame| (frame == 3).then { canvas[0] = 0x01 } }

    assert_equal RED, pixel(prog, 10, 0, 0)
  end

  # The second tile is bytes 32 to 63; its top-left pixel is the low half of byte 32. The
  # right pixel of a pair is the HIGH half, which is the one a game gets wrong first.
  def test_the_second_tile_and_the_right_pixel_of_a_byte_land_where_the_console_puts_them
    prog = game do |canvas, box, frame|
      (frame == 2).then do
        canvas[32] = 0x10 # tile 2, row 0: the left pixel see-through, the right one white
        box.changed
      end
    end

    assert_equal RED, pixel(prog, 5, 8, 0)
    assert_equal WHITE, pixel(prog, 5, 9, 0)
  end

  def test_one_box_shown_in_two_scenes_shows_its_list_in_each
    prog = shared_box_game

    assert_equal WHITE, pixel(prog, 4, 0, 0), "painted in the house, shown there"
    assert_equal WHITE, pixel(prog, 7, 0, 0), "the shop puts the box up from the list as it is"
    assert_equal WHITE, pixel(prog, 10, 8, 0), "painted in the shop, shown there"
    assert_equal WHITE, pixel(prog, 14, 8, 0), "and back in the house"
  end

  def test_the_console_agrees_on_one_box_in_two_scenes
    [4, 7, 10, 14].each { |frames| assert_backends_agree(shared_box_game, frames: frames) }
  end

  # A box every screen shows, and the same box shown again by one scene's own background —
  # a status line along the top, repeated beside the shopkeeper. The scene's copy is the one
  # every screen already has, so both show the same pixels.
  def test_a_box_every_screen_shows_can_be_shown_again_by_a_scene
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 2, colors: :ink
      background :top_box, tiles: :box, map: [[1, 2]]
      state = var :state, 0
      frame = var :frame, 0
      scene(:house) { (frame == 3).then { state.set! 1 } }
      scene(:shop) do
        background :shop_box, tiles: :box, map: [[nil, nil, 1, 2]]
        (frame == 5).then { canvas[0] = 0x01; box.changed }
      end
      game_loop do
        frame.add! 1
        case_var(:state) { when_val 0, :house; when_val 1, :shop }
      end
    end
    b.finalize_program

    assert_equal WHITE, pixel(b.program, 8, 16, 0), "the shop's own copy shows the pixel"
    assert_backends_agree(b.program, frames: 8)
  end

  # The frame a write shows on, and what a scene shows as it takes over again, are the two
  # rules a backend could get subtly wrong; both are compared here at the frames that decide.
  def test_the_console_agrees_on_when_a_copy_shows
    prog = game do |canvas, box, frame|
      (frame == 3).then { canvas[0] = 0x01; box.changed }
    end
    [3, 4].each { |frames| assert_backends_agree(prog, frames: frames) }
  end
end
