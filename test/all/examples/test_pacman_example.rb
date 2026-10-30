# frozen_string_literal: true

require "test_helper"

require "stringio"
require "differential"
require VBlank.root.join("examples/pacman").to_s

# The Pac-Man example (examples/pacman.rb): the tiled-mode flagship. Pac, the
# pellets, and the ghost are HARDWARE sprites composited over a TILED room; Pac
# faces the way he moves, eats pellets on contact, and the ghost chases him. Asserts
# the whole stack renders and behaves, on every run's player; the Advance's cartridge
# read back in the emulator is in test/lowering/gba/examples/test_pacman_example_cartridge.rb.
# (Facing correctness itself is pinned in test_hardware_sprite_facing.rb.)
class TestPacmanExample < Minitest::Test
  include Differential

  # Is there a pixel of +color+ anywhere in the box (x0..x1, y0..y1)?
  private def any_pixel?(screen, color, x_range, y_range)
    want = Color.resolve(color)
    x_range.any? { |x| y_range.any? { |y| screen.pixel(x, y) == want } }
  end

  # The game as this run's console plays it, and where it lays itself out on that console's screen.
  private def program = Pacman::GAME.program(console: game_console)
  private def screen_size = VBlank::Console.described(game_console).screen_size
  private def layout = Pacman::Layout.new(width: screen_size[0], height: screen_size[1])

  # Pac (yellow), a pellet (white), and the ghost (red) all render over the room —
  # three hardware sprites of different colors composited on the tiled background.
  def test_pac_the_pellets_and_the_ghost_all_render
    s = game_player.run(program, max_steps: 400).screen
    x, y = layout.start
    assert any_pixel?(s, :yellow, x..(x + Pacman::SIZE), y..(y + Pacman::SIZE)), "Pac-Man renders in the middle"
    px, py = layout.pellet_spots.first
    assert any_pixel?(s, :white, px..(px + 8), py..(py + 8)), "a pellet renders"
    # the ghost is the only red thing, and it's already creeping toward Pac
    assert any_pixel?(s, :red, 0...screen_size[0], 0...screen_size[1]), "the ghost renders"
  end

  # Holding left walks Pac left of where he started — he's found in yellow there.
  def test_steering_moves_pac
    s = game_player.input_each_frame { [:left] }.run(program, max_steps: 400).screen
    x, y = layout.start
    assert any_pixel?(s, :yellow, (x - 48)..(x - 8), y..(y + Pacman::SIZE)),
           "holding left should walk Pac left of centre"
  end

  # A pellet sits directly above Pac, so just holding up walks him into it — well
  # before the ghost (starting in a far corner) is any threat. overlaps? fires and
  # the eaten count climbs. Both are sprites, so there are no boxes.
  def test_eating_a_pellet
    r = game_player.input_each_frame { [:up] }.run(program, max_steps: 1000)
    assert_operator r[:eaten], :>=, 1, "walking into a pellet should eat it"
  end

  # Leave Pac still and the ghost, creeping toward him each frame, eventually catches
  # him — collision across two moving hardware sprites, driving the whole loop.
  def test_the_ghost_catches_an_idle_pac
    r = game_player.run(program, max_steps: 4000)
    assert_operator r[:caught], :>=, 1, "the chasing ghost should catch a still Pac"
  end

  # Caught, Pac blinks: drawn white from a second list of colours for a moment, then his own
  # yellow again. Left alone, the ghost closes a pixel a frame on each side, so it reaches him
  # once it has come the longer of the two distances less a sprite's width: a little after
  # frame 70 on the Advance, and sooner on the Color's smaller screen. He blinks four frames
  # white and four his own yellow from then on, so he is white eight frames after that and
  # yellow four frames later. (On the Color an idle Pac is caught again before the blinking
  # ends, so the test takes one blink rather than its end.)
  private def caught_at = layout.start.zip(Pacman::GHOST_START).map { |pac, ghost| pac - ghost }.max - Pacman::SIZE
  private def caught_and_white = caught_at + 8
  private def blinked_back = caught_at + 12

  private def pac_centre(screen) = layout.start.then { |x, y| screen.pixel(x + 8, y + 8) }

  def test_a_caught_pac_blinks_white_then_is_yellow_again
    assert_equal Color.resolve(:white), pac_centre(game_player.run(program, frames: caught_and_white).screen)
    assert_equal Color.resolve(:yellow), pac_centre(game_player.run(program, frames: blinked_back).screen)
  end

  # --- the whole picture, as the run's own player draws it ---

  def test_the_console_blinks_him_white_too
    oracle, console, = backend_pictures(program, frames: caught_and_white)

    assert_equal Color.resolve(:white), layout.start.then { |x, y| pixel_at(console, x + 8, y + 8) }
    assert_empty mismatched_pixels(oracle, console)
  end

  # Building the cartridge, and Pac rendering and steering on it in the emulator, are in
  # test/lowering/gba/examples/test_pacman_example_cartridge.rb.
end
