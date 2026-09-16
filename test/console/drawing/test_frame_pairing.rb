# frozen_string_literal: true

require "test_helper"

# WHICH FRAME'S NUMBERS THE PICTURE WAS DRAWN FROM.
#
# A test that reads a pixel and a variable at the same moment is reading two things that
# were not necessarily decided at the same moment, and which of the two you are looking at
# depends on who drew it:
#
#   - What the PROGRAM draws (a rectangle, a pixel, a picture blitted somewhere) lands on
#     the screen in the pass that drew it, so the picture and the variable agree.
#   - What the FRAMEWORK draws for you every frame — a sprite, a HUD number, a background's
#     scroll — is painted in the gap before the next frame, from the variables as they stand
#     then. So the picture shows the value from the pass BEFORE the one whose variables you
#     are reading.
#
# That is not a cost of either backend: a position decided while a frame is being drawn
# cannot appear in that frame, on a console or anywhere else. Both backends agree, which is
# what these tests pin — each reads the variable and the picture from the SAME backend at
# the same moment and asserts how the two line up, so nothing here depends on the two
# backends counting frames from the same place.
#
# It is pinned because getting it wrong costs an afternoon: the test says the game is drawing
# a frame early and the game is right.
class TestFramePairing < Minitest::Test
  STEP = 8    # pixels the marker moves per frame, so its column IS the variable
  ROW = 84    # the row both markers sit on
  FRAMES = 6  # long enough to be past the first frame, short enough to stay on screen

  # A marker the program draws itself, moved one step per frame.
  HAND_DRAWN = proc do
    screen :bitmap
    n = var :n, 0
    game_loop do
      clear_screen :black
      n.add! 1
      draw_rect_at n * TestFramePairing::STEP, TestFramePairing::ROW, 4, 4, :red
    end
  end

  # The same marker as a sprite — moved the same way, but painted by the framework.
  A_SPRITE = proc do
    screen :tiled
    image :hero, "#" => :red do
      <<~ART
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
    end
    n = var :n, 0
    hero = sprite :hero, at: [0, TestFramePairing::ROW]
    game_loop do
      n.add! 1
      hero.move_to n * TestFramePairing::STEP, TestFramePairing::ROW
    end
  end

  def test_the_interpreter_draws_a_programs_own_marker_from_this_frames_value
    interpreter_pairs(HAND_DRAWN).each do |value, drawn|
      assert_equal value, drawn,
                   "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
    end
  end

  def test_the_interpreter_draws_a_sprite_from_the_frame_befores_value
    interpreter_pairs(A_SPRITE).each do |value, drawn|
      assert_equal value - 1, drawn,
                   "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
    end
  end

  def test_the_console_draws_a_programs_own_marker_from_this_frames_value
    value, drawn = console_pair(HAND_DRAWN)

    assert_equal value, drawn,
                 "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
  end

  def test_the_console_draws_a_sprite_from_the_frame_befores_value
    value, drawn = console_pair(A_SPRITE)

    assert_equal value - 1, drawn,
                 "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
  end

  private

  # Play the program and collect, at every frame boundary, what the variable holds and what
  # value the picture on screen was drawn from. The first boundary is left out: nothing has
  # been drawn yet, so there is no picture to pair with.
  def interpreter_pairs(source)
    interp = Reference.new
    pairs = []
    interp.each_vblank do |frame|
      drawn = marker_column { |x, y| interp.screen.pixel(x, y).to_i.positive? }
      pairs << [interp[:n], drawn] if frame > 1
    end
    interp.run(tree_of(source), frames: FRAMES)
    refute_empty pairs
    pairs
  end

  # The same pair read off the console, the way a game's own test reads them: run the ROM
  # for a number of frames, then read a variable and a pixel.
  def console_pair(source)
    rom = RubyGBA.build("PAIRING", validate: false, &source)
    verifier = assert_emulator_loads_rom(rom, frames: FRAMES, vars: rom.var_addresses)
    [verifier.var(:n), marker_column { |x, y| verifier.red?(x, y) }]
  end

  # Which step along the row the marker is sitting on — the value it was drawn from.
  def marker_column
    column = (0...240).step(STEP).find { |x| yield(x + 1, ROW + 1) }
    column && column / STEP
  end

  def tree_of(source)
    builder = Builder.new
    builder.instance_eval(&source)
    builder.emit_pending_functions
    builder.program
  end
end
