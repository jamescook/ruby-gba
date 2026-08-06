# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/pacman"

# The Pac-Man example (examples/pacman.rb): the tiled-mode flagship. Pac, the
# pellets, and the ghost are HARDWARE sprites composited over a TILED room; Pac
# faces the way he moves, eats pellets on contact, and the ghost chases him. Asserts
# the whole stack renders and behaves — on the interpreter oracle and on real
# hardware. (Facing correctness itself is pinned in test_hardware_sprite_facing.rb.)
class TestPacmanExample < Minitest::Test
  include RubyGBA::Constants

  START_X, START_Y = Pacman::START

  # Is there a pixel of +color+ anywhere in the box (x0..x1, y0..y1)?
  def any_pixel?(screen, color, x_range, y_range)
    want = Color.resolve(color)
    x_range.any? { |x| y_range.any? { |y| screen.pixel(x, y) == want } }
  end

  def test_it_builds_a_rom
    assert_operator Pacman.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  # Pac (yellow), a pellet (white), and the ghost (red) all render over the room —
  # three hardware sprites of different colors composited on the tiled background.
  def test_pac_the_pellets_and_the_ghost_all_render
    s = Reference.new.run(Pacman.program, max_steps: 400).screen
    assert any_pixel?(s, :yellow, START_X..(START_X + Pacman::SIZE), START_Y..(START_Y + Pacman::SIZE)),
           "Pac-Man renders in the middle"
    px, py = Pacman::PELLET_SPOTS.first
    assert any_pixel?(s, :white, px..(px + 8), py..(py + 8)), "a pellet renders"
    # the ghost is the only red thing, and it's already creeping toward Pac
    assert any_pixel?(s, :red, 0..239, 0..159), "the ghost renders"
  end

  # Holding left walks Pac left of where he started — he's found in yellow there.
  def test_steering_moves_pac
    s = Reference.new.input_each_frame { [:left] }.run(Pacman.program, max_steps: 400).screen
    assert any_pixel?(s, :yellow, 64..104, START_Y..(START_Y + Pacman::SIZE)),
           "holding left should walk Pac left of centre"
  end

  # A pellet sits directly above Pac, so just holding up walks him into it — well
  # before the ghost (starting in a far corner) is any threat. overlaps? fires and
  # the eaten count climbs. Both are sprites, so there are no boxes.
  def test_eating_a_pellet
    r = Reference.new.input_each_frame { [:up] }.run(Pacman.program, max_steps: 1000)
    assert_operator r[:eaten], :>=, 1, "walking into a pellet should eat it"
  end

  # Leave Pac still and the ghost, creeping toward him each frame, eventually catches
  # him — collision across two moving hardware sprites, driving the whole loop.
  def test_the_ghost_catches_an_idle_pac
    r = Reference.new.run(Pacman.program, max_steps: 4000)
    assert_operator r[:caught], :>=, 1, "the chasing ghost should catch a still Pac"
  end

  # --- Hardware (gemba): it renders and steers on the console ---

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(Pacman.program), title: "PACMAN", code: "BPAC", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    moved = (40...START_X).any? { |x| (START_Y...START_Y + Pacman::SIZE).any? { |y| v.pixel_is?(x, y, :yellow) } }
    assert moved, "Pac-Man should be found in yellow left of centre on hardware"
    gx, gy = Pacman::GHOST_START
    ghost_there = (gx...gx + Pacman::SIZE).any? { |x| (gy...gy + Pacman::SIZE).any? { |y| v.red?(x, y) } }
    assert ghost_there, "the ghost should render on hardware"
  end
end
