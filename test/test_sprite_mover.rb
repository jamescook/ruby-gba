# frozen_string_literal: true

require "test_helper"

# The sprite-mover example in miniature: a transparent ASCII heart steered by
# holding a direction. Proves image (ASCII art + transparency) + blit +
# held-input move a sprite, on both backends.
class TestSpriteMover < Minitest::Test
  include RubyGBA::Constants

  # A heart that starts at (100, 60), slides right while :right is held, and halts
  # after +frames+ steps so its final resting place is deterministic. Holding
  # right for 4 frames leaves it at x = 108.
  def sprite_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image :heart, "." => :transparent, "#" => :red do
        <<~ART
          .#.#.
          #####
          #####
          .###.
          ..#..
        ART
      end
      x = var :x, 100
      var :y, 60
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :white
        held(:right).then { x.add 2 }
        x.clamp 0, 235
        blit :heart, :x, :y
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_interpreter_moves_the_sprite_and_keeps_transparency
    screen = Reference.new.input_each_frame { [:right] }.run(sprite_program(frames: 4)).screen

    # Ended at x = 108. The heart's top-left is a transparent ".", so the white
    # field shows through; the "#" next to it is red.
    assert_equal Color.resolve(:white), screen.pixel(108, 60), "transparent corner shows the background"
    assert_equal Color.resolve(:red),   screen.pixel(109, 60), "the heart's body is drawn"
    # It actually moved: the screen is cleared each frame, so the earlier columns
    # hold no heart.
    assert_equal Color.resolve(:white), screen.pixel(100, 61), "it moved off the start column"
  end

  def test_runs_on_hardware
    machine_code = RubyGBA::IR::Backends::GBA.new.lower(sprite_program(frames: 4))
    rom = RubyGBA::ROM.assemble(machine_code, title: "SPRITEMV", code: "BSPM", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 6, keys: KEY_RIGHT)
    assert v.red?(109, 60),   "the heart is drawn after moving right"
    assert v.white?(108, 60), "its transparent corner shows the white field"
  end

  # Like the example, the heart may slide half off an edge (clamped so it never
  # fully vanishes). Here it's pushed left until it hangs off the left edge, and
  # only its on-screen part draws — the columns off-screen are clipped, not
  # wrapped onto the previous row.
  #
  #   heart art, x = -2 (top-left off the left edge):
  #       col: 0  1  2  3  4        screen_x = col - 2
  #   row0:    .  #  .  #  .   ->   lit col1 @ -1 (clipped), col3 @ 1 (drawn)
  #   row1:    #  #  #  #  #   ->   cols 2,3,4 @ 0,1,2 drawn; cols 0,1 clipped
  def heart_at_left_edge(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image :heart, "." => :transparent, "#" => :red do
        <<~ART
          .#.#.
          #####
          #####
          .###.
          ..#..
        ART
      end
      x = var :x, 2
      var :y, 60
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :white
        held(:left).then { x.sub 2 }
        x.clamp(-2, 237) # same half-off-edge clamp the example uses
        blit :heart, :x, :y
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # The visible/clipped pixels the heart shows once it rests at x = -2, y = 60.
  # A nil colour means "background (white) here" — clipped or transparent.
  EDGE_PIXELS = [
    [1, 60, :red],    # row0 col3 lands on-screen
    [0, 60, :white],  # row0 col2 is transparent -> field shows through
    [0, 61, :red],    # row1 col2
    [2, 61, :red],    # row1 col4 (the rightmost visible column of that row)
    [239, 59, nil],   # the col clipped off the left must NOT wrap onto the row above
  ].freeze

  def test_interpreter_clips_the_heart_at_the_left_edge
    screen = Reference.new.input_each_frame { [:left] }.run(heart_at_left_edge(frames: 3)).screen
    EDGE_PIXELS.each do |x, y, color|
      assert_equal Color.resolve(color || :white), screen.pixel(x, y),
                   "interpreter: (#{x}, #{y}) should be #{color || 'background'}"
    end
  end

  def test_hardware_clips_the_heart_at_the_left_edge
    rom = RubyGBA::ROM.assemble(
      RubyGBA::IR::Backends::GBA.new.lower(heart_at_left_edge(frames: 3)),
      title: "SPRITEMV", code: "BSPM", maker: "01",
    )
    v = assert_gemba_loads_rom(rom, frames: 5, keys: KEY_LEFT)
    EDGE_PIXELS.each do |x, y, color|
      assert v.pixel_is?(x, y, color || :white),
             "console: (#{x}, #{y}) should be #{color || 'background'}, got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end
end
