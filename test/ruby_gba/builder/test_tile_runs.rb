# frozen_string_literal: true

require "test_helper"
require "differential"

# TILES WHOSE PIXELS COME FROM A LIST THE GAME OWNS — `tiles :box, from: list, count: n`.
#
# Every other tile a game has is a picture fixed while the cartridge is built. These are the
# ones a game paints as it runs: a name, a count, a message typed a letter at a time, a meter,
# a map drawn from where the player has been. The game writes the pixels into a list and says
# `changed`; the list shows on the next frame.
#
# The list holds the pixels the way the console does: each byte is two pixels, the left one in
# the low four bits, and each of those four bits is a place in the run's colour list — 0 is
# see-through. A tile is 8 rows of 4 bytes, so 32 bytes, and tile 2 starts at byte 32.
class TestTileRuns < Minitest::Test
  RED = RubyGBA::Graphics::Color.resolve(:red)
  WHITE = RubyGBA::Graphics::Color.resolve(:white)

  # A red backdrop behind a two-tile run, side by side at the top left. +body+ runs every
  # pass with the list, the run's handle and a frame counter.
  def game(&body)
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

  def pixel(prog, frames, x, y) = Reference.new.run(prog, frames: frames).screen.pixel(x, y)

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

  # A scene that takes over again puts its run up from the list as it is then — the scene in
  # between used the same video memory, so the list is the only place the pixels still are.
  # Here the pixel is drawn and shown in the first visit, wiped from the list (unannounced)
  # in the second scene, and gone when the first comes back.
  def scene_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      state = var :state, 0
      frame = var :frame, 0
      scene(:talking) do
        box = tiles :box, from: canvas, count: 2, colors: :ink
        background :front, tiles: :box, map: [[1, 2]]
        (frame == 2).then { canvas[0] = 0x01; box.changed }
        (frame == 5).then { state.set! 1 }
      end
      scene(:walking) do
        (frame == 7).then { canvas[0] = 0x00 }
        (frame == 9).then { state.set! 0 }
      end
      game_loop do
        frame.add! 1
        case_var(:state) { when_val 0, :talking; when_val 1, :walking }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_scene_taking_over_again_shows_its_list_as_it_is_then
    assert_equal WHITE, pixel(scene_game, 4, 0, 0), "shown in the first visit"
    assert_equal 0, pixel(scene_game, 13, 0, 0), "back again, it shows the list as it is now"
  end

  def test_the_console_agrees_on_what_a_scene_shows_as_it_takes_over_again
    [4, 13].each { |frames| assert_backends_agree(scene_game, frames: frames) }
  end

  include Differential

  # Every byte of both tiles gets a different pattern of places from a four-colour list, so a
  # copy that landed a tile late, a byte off, or with its two pixels swapped draws a different
  # picture somewhere — and the whole screen is compared, console against interpreter.
  def patterned_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent white red blue]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { |i| canvas.push((i * 7) & 0xFF) }
      box = tiles :box, from: canvas, count: 2, colors: :ink
      background :front, tiles: :box, map: [[1, 2], [2, 1]]
      game_loop { box.changed }
    end
    b.finalize_program
    b.program
  end

  def test_the_console_paints_the_same_tiles_as_the_interpreter
    oracle, console = backend_pictures(patterned_game, frames: 4)

    assert_equal [WHITE, RED, RubyGBA::Graphics::Color.resolve(:blue)].sort,
                 (oracle.uniq - [0]).sort, "the pattern draws all three colours, so the comparison means something"
    assert_empty mismatched_pixels(oracle, console), "the console paints the run as the interpreter does"
  end

  # The frame a write shows on, and what a scene shows as it takes over again, are the two
  # rules a backend could get subtly wrong; both are compared here at the frames that decide.
  def test_the_console_agrees_on_when_a_copy_shows
    prog = game do |canvas, box, frame|
      (frame == 3).then { canvas[0] = 0x01; box.changed }
    end
    [3, 4].each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # --- a sprite's picture from a list ---

  # A 16x8 picture is two tiles side by side, so its list is 64 bytes, the left tile first —
  # the order the console keeps a sprite's tiles in. +body+ runs each pass with the list, the
  # picture's handle and a frame counter.
  def tag_game(&body)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      tag = image :tag, from: canvas, width: 16, height: 8, colors: :ink
      sprite :tag, at: [40, 20]
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        instance_exec(canvas, tag, frame, &body)
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_sprite_shows_its_lists_pixels_on_the_frame_after_changed
    prog = tag_game do |canvas, tag, frame|
      (frame == 3).then do
        canvas[32] = 0x01 # the second tile's top-left pixel: 8 across from the sprite's corner
        tag.changed
      end
    end

    refute_equal WHITE, pixel(prog, 3, 48, 20), "not on the frame it was written"
    assert_equal WHITE, pixel(prog, 4, 48, 20), "on the next frame, the same as tiles a background shows"
  end

  def test_the_console_agrees_on_a_sprites_painted_picture_and_when_it_shows
    prog = tag_game do |canvas, tag, frame|
      (frame == 3).then do
        repeat(64) { |i| canvas[i] = (i * 7) & 0xFF }
        tag.changed
      end
    end
    oracle, console = backend_pictures(prog, frames: 5)

    assert_includes oracle, WHITE, "the pattern shows, so the comparison means something"
    assert_empty mismatched_pixels(oracle, console)
    [3, 4].each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # The sprite side of a scene coming back: its painted picture goes up from the list as it is
  # then, so a pixel wiped from the list while the scene was away is gone on return.
  def tag_scene_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(32) { canvas.push 0 }
      state = var :state, 0
      frame = var :frame, 0
      scene(:talking) do
        tag = image :tag, from: canvas, width: 8, height: 8, colors: :ink
        sprite :tag, at: [0, 0]
        (frame == 2).then { canvas[0] = 0x01; tag.changed }
        (frame == 5).then { state.set! 1 }
      end
      scene(:walking) do
        (frame == 7).then { canvas[0] = 0x00 }
        (frame == 9).then { state.set! 0 }
      end
      game_loop do
        frame.add! 1
        case_var(:state) { when_val 0, :talking; when_val 1, :walking }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_painted_sprite_back_with_its_scene_shows_its_list_as_it_is_then
    assert_equal WHITE, pixel(tag_scene_game, 4, 0, 0)
    assert_equal 0, pixel(tag_scene_game, 13, 0, 0)
    [4, 13].each { |frames| assert_backends_agree(tag_scene_game, frames: frames) }
  end

  # Three save slots, each with a name tag of its own: three lists, three pictures.
  def three_tags
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent white red blue]
      tags = (0..2).map do |slot|
        canvas = list :"name_#{slot}", capacity: 32, width: :byte
        repeat(32) { canvas.push slot + 1 } # every left pixel is place slot + 1
        tag = image :"tag_#{slot}", from: canvas, width: 8, height: 8, colors: :ink
        sprite :"tag_#{slot}", at: [slot * 10, 0]
        tag
      end
      game_loop { tags.each(&:changed) }
    end
    b.finalize_program
    b.program
  end

  def test_three_sprites_each_show_their_own_list
    shown = (0..2).map { |slot| pixel(three_tags, 3, slot * 10, 0) }

    assert_equal [WHITE, RED, RubyGBA::Graphics::Color.resolve(:blue)], shown
  end

  def test_the_console_shows_each_sprites_own_list_too
    assert_backends_agree(three_tags, frames: 3)
  end

  def refusal(screen_kind: :tiled, &block)
    assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen screen_kind
        colors :ink, [:transparent, :white]
        instance_eval(&block)
      end
    end.message
  end

  def test_mistakes_are_friendly_errors
    assert_match(/use `pixel` or `blit`/,
                 refusal(screen_kind: :bitmap) { tiles :box, from: list(:c, capacity: 64, width: :byte), count: 2, colors: :ink })
    assert_match(/`count:`/, refusal { tiles :box, from: list(:c, capacity: 64, width: :byte), count: 0, colors: :ink })
    assert_match(/must hold bytes/, refusal { tiles :box, from: list(:c, capacity: 64), count: 2, colors: :ink })
    message = refusal { tiles :box, from: list(:c, capacity: 40, width: :byte), count: 2, colors: :ink }
    assert_match(/needs a capacity of 64/, message)
    assert_match(/It has 40/, message)
    assert_match(/no list has that name/, refusal { tiles :box, from: list(:c, capacity: 64, width: :byte), count: 2, colors: :nope })
    assert_match(/2 to 16 colors/, refusal { tiles :box, from: list(:c, capacity: 64, width: :byte), count: 2 })
    assert_match(/sizes are 8x8/, refusal { image :tag, from: list(:c, capacity: 64, width: :byte), width: 24, height: 8, colors: :ink })
    assert_match(/use `pixel` or `blit`/,
                 refusal(screen_kind: :bitmap) { image :tag, from: list(:c, capacity: 64, width: :byte), width: 16, height: 8, colors: :ink })
    assert_match(/keys 1 to 2/, refusal do
      image(:w, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :box, from: list(:c, capacity: 64, width: :byte), count: 2, colors: :ink, 2 => :w
    end)
  end

  # A box's frame drawn from fixed tiles round the run, in one tileset. The run's tiles are
  # 1 and 2; the frame's key is a character.
  def test_fixed_tiles_sit_beside_the_run_in_one_tileset
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      tiles :box, from: canvas, count: 2, colors: :ink, "=" => :white_tile
      background :front, tiles: :box, map: [["=", 1, 2]]
      game_loop {}
    end
    b.finalize_program

    assert_equal WHITE, pixel(b.program, 2, 0, 0)
  end
end
