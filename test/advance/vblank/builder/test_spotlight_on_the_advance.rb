# frozen_string_literal: true

require "test_helper"
require "differential"
require "midpoint_circle"

# The tests of test_spotlight.rb whose games light the screen with a spotlight, a window and a
# darkening a Game Boy Color's hardware does not have, so they play on the Advance's runs alone.
#
# A light the game moves: the picture as drawn inside a circle, and darkened everywhere
# outside it.
#
# The console does it with its first window — a rectangle whose left and right edge are
# given a new value on every row of the screen, so it comes out round — and its darkening
# effect switched on outside the window only. So the things to assert are the two halves
# of that: inside the circle nothing changes, outside it every pixel is darkened by the
# amount the light says; and then that the console draws the same picture pixel for pixel,
# which is what holds the circle's edge to one rule on both backends.
class TestSpotlightOnTheAdvance < Minitest::Test
  include Differential
  include MidpointCircle # and its WIDTH and HEIGHT, the screen's

  WHITE = Color.resolve(:white)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room drawn all in white, with a light at (120, 80) and +said+ run before the loop.
  private def lit_room(radius: 40, dark: 75, &said)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: radius, dark: dark
      instance_exec(light, &said) if said
      game_loop {}
    end
  end

  private def shown(program, frames: 2) = game_player.run(program, frames: frames).screen

  # White taken three quarters of the way to black the way the emulator's display does it,
  # at eight bits a channel: red comes to 64 of 255, which is 8, and green and blue lose
  # the fraction of their share where they sit in the number and come to 63, which is 7.
  # (Five bits throughout would be 8 in every channel.) See Framebuffer#darkened_by_display.
  THREE_QUARTERS_DARK = Color.rgb(8, 7, 7)

  def test_the_picture_is_as_drawn_inside_the_light_and_darkened_outside_it
    screen = shown(lit_room)

    assert_equal WHITE, screen.pixel(120, 80), "the middle of the light"
    assert_equal WHITE, screen.pixel(150, 80), "thirty pixels right of it, inside"
    assert_equal WHITE, screen.pixel(120, 105), "twenty-five below it, inside"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(170, 80), "fifty right of it, outside"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(5, 5), "a corner of the screen"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(150, 110), "thirty right and thirty down is past forty"
  end

  def test_the_console_draws_the_same_light
    assert_backends_agree(lit_room, frames: 2)
  end

  # The light is where the handle says at the end of a frame: moved, grown and made darker
  # as the game runs, it is worked out again before the next one.
  def test_a_light_the_game_moves_is_drawn_where_it_went
    moving = lit_room(radius: 20) do |light|
      step = var :step, 0
      once_a_frame do
        step.add! 1
        light.move_to 40 + step * 10, 30 + step * 5
        light.radius.set! 20 + step * 4
        light.dark.set! 100
      end
    end
    screen = shown(moving, frames: 4)
    black = Color.rgb(0, 0, 0)

    assert_equal black, screen.pixel(120, 80), "where the light started is dark now"
    refute_equal black, screen.pixel(70, 45), "the middle of where it went after three frames"
    assert_backends_agree(moving, frames: 4)
  end

  # A light that reaches past the edges of the screen — and one whose middle is off it —
  # lights what it covers and no more, and comes out the same on both backends.
  def test_a_light_past_the_edges_of_the_screen
    [[-30, 80, 60], [230, 5, 50], [120, 300, 200], [10, 150, 400]].each do |x, y, radius|
      game = lit_room(radius: radius) { |light| light.move_to x, y }
      assert_backends_agree(game, frames: 2, name: "AT#{x}X#{y}")
    end
  end

  # A radius of nothing lights nothing, and a light of no darkness changes nothing.
  def test_a_light_of_no_size_or_no_darkness
    dark = shown(lit_room(radius: 0))

    assert_equal THREE_QUARTERS_DARK, dark.pixel(120, 80)
    assert_equal WHITE, shown(lit_room(dark: 0)).pixel(5, 5)
    assert_backends_agree(lit_room(radius: 0), frames: 2, name: "NOSIZE")
  end

  # A LIGHT BESIDE THREE BENDING LAYERS is one more thing fed a row at a time than the
  # console has engines to feed with, so every one of them is fed by the interrupt at the
  # end of each line instead — the same picture, the CPU carrying the numbers.
  def test_a_light_fed_by_the_line_interrupt_draws_the_same_picture
    crowded = program do
      screen :tiled
      layers :far, :middle, :near
      image(:stripe, "#" => :white, "." => :transparent) { (["#...#..."] * 8).join("\n") }
      tiles :set, "#" => :stripe
      %i[far middle near].each_with_index do |name, i|
        layer(name) { background(name, tiles: :set, map: ["#" * 32] * 32).scroll_each_row { |row| (row + i) % 3 } }
      end
      spotlight at: [120, 80], radius: 50, dark: 100
      game_loop {}
    end

    assert_match(/a spotlight/, VBlank::IR::Backends::GBA::BendForm.kept_interrupt_reason(crowded))
    assert_backends_agree(crowded, frames: 2)
  end

  # --- the circle's edge, row by row ---

  # THE CIRCLE A LIGHT LIGHTS IS THE MIDPOINT CIRCLE, the one games of this console draw their
  # window circles with, so a game copying one lands on every pixel of it. The game's own circle
  # is in test/midpoint_circle.rb, written from its code; a shape of the game's own is in
  # test/vblank/dsl/test_spotlight_shape.rb.
  def test_each_row_of_the_light_is_the_midpoint_circles
    [[120, 80, 82], [120, 80, 1], [120, 80, 2], [120, 80, 150], [184, 96, 4], [184, 96, 37],
     [0, 0, 30], [239, 159, 61], [30, 150, 146]].each do |x, y, size|
      assert_same_spans game_circle_spans(x, y, size),
                        lit_spans(shown(lit_room(radius: size, dark: 100) { |light| light.move_to x, y })),
                        "a light of size #{size} at (#{x}, #{y})"
    end
  end

  # One row read off the real cartridge rather than worked out by the copy above, so a slip made
  # the same way in the copy and in the framework would still be caught: at size 82 centred on
  # (120, 80), the top row of the screen is lit from column 100 up to 140.
  def test_the_top_row_of_a_size_82_circle_is_the_cartridges
    assert_equal [100, 140], lit_spans(shown(lit_room(radius: 82, dark: 100)))[0]
  end

  def test_the_console_draws_the_midpoint_circle
    [[120, 80, 82], [184, 96, 146], [239, 0, 9]].each do |x, y, size|
      game = lit_room(radius: size, dark: 100) { |light| light.move_to x, y }
      assert_backends_agree(game, frames: 2, name: "MID#{size}")
    end
  end

  # Every size an iris passes through, one a frame, read off one run: the size the game sets in a
  # frame is drawn on the next picture, as a sprite's place is.
  def test_every_size_up_to_150_is_the_midpoint_circle
    walking = lit_room(radius: 0, dark: 100) do |light|
      once_a_frame { (light.radius < 150).then { light.radius.add! 1 } }
    end
    seen = []
    run = game_player
    run.each_vblank { seen << lit_spans(run.screen) }
    run.run(walking, frames: 152)

    (0..150).each do |size|
      assert_same_spans game_circle_spans(120, 80, size), seen[size + 1], "a light of size #{size}"
    end
  end

  # --- a light beside the other things that darken a picture ---

  # A FADE AND A LIGHT ARE BOTH IN FORCE. The display has one darkening, and the light holds
  # it, so a game with a light fades by walking its colours — the whole picture goes half
  # way to black, and outside the light it is then darkened again on top.
  def test_a_fade_darkens_the_whole_picture_and_the_light_still_shows
    faded = lit_room { fade :black, 50 }
    screen = shown(faded)

    inside = screen.pixel(120, 80)
    outside = screen.pixel(5, 5)

    refute_equal WHITE, inside, "the fade reaches inside the light"
    refute_equal Color.rgb(0, 0, 0), inside
    assert (outside & 31) < (inside & 31), "outside the light is darker than inside it"
    assert_backends_agree(faded, frames: 2)
  end

  # --- a light that takes turns with another scene's mixing ---

  # A title that sees through red water to a white room, then from frame 6 a scene with a light
  # of darkness 100. +back+ starts in the lit scene and goes to the title instead.
  private def title_then_light(title: nil, back: false)
    title ||= -> { layer(:water, transparency: 50) { background :pond, tiles: :set, map: ["r" * 32] * 32 } }
    program do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      mode = var :mode, back ? 1 : 0
      turn = var :turn, 0
      spotlight at: [120, 80], radius: 40, dark: 100
      scene(:title) { instance_exec(&title) }
      scene(:playing) {}
      game_loop do
        turn.add! 1
        (turn == 6).then { mode.set! back ? 0 : 1 }
        case_var(:mode) { when_val 0, :title; when_val 1, :playing }
      end
    end
  end

  # The frames compared: either side of the change of scene on frame 6, and well after it.
  TURN_FRAMES = [3, 6, 7, 8, 12].freeze

  # THE LIGHT IS OFF IN A SCENE THAT SEES THROUGH A LAYER, and on in the rest: the display's
  # mixing is told afresh every frame, so the title's water is mixed and the next scene is lit.
  def test_a_light_is_off_in_a_scene_that_sees_through_a_layer
    title = shown(title_then_light, frames: 3)
    playing = shown(title_then_light, frames: 12)

    assert_equal title.pixel(120, 80), title.pixel(5, 5), "the title is mixed the same everywhere"
    refute_equal WHITE, title.pixel(5, 5), "...with the water in it"
    refute_equal Color.rgb(0, 0, 0), title.pixel(5, 5), "...and not darkened"
    assert_equal WHITE, playing.pixel(120, 80), "the next scene is lit inside the light"
    assert_equal Color.rgb(0, 0, 0), playing.pixel(5, 5), "and dark outside it"
  end

  def test_the_console_takes_turns_the_same_way
    assert_backends_agree(title_then_light, frames: TURN_FRAMES, name: "TURNS")
  end

  # The same with a fade placed in the stack in place of the water: the title is half faded
  # under the water's place, the light off, and then the next scene is lit.
  def test_a_light_is_off_in_a_scene_that_fades_under_a_layer
    fading = title_then_light(title: lambda {
      layer(:water) { background :pond, tiles: :set, map: ["r" * 32] * 32 }
      fade :black, 50, under: :water
    })
    title = shown(fading, frames: 3)

    assert_equal title.pixel(120, 80), title.pixel(5, 5), "the title is faded the same everywhere"
    assert_backends_agree(fading, frames: TURN_FRAMES, name: "FADES")
  end

  # ...and back again: coming back to the title from the lit scene, the water is mixed again.
  def test_coming_back_to_a_scene_that_sees_through_a_layer_turns_the_light_off_again
    back = title_then_light(back: true)
    screen = shown(back, frames: 12)

    assert_equal screen.pixel(120, 80), screen.pixel(5, 5), "the title is mixed the same everywhere again"
    assert_backends_agree(back, frames: TURN_FRAMES, name: "BACK")
  end

  # THE CONSOLE KEEPS A LIGHT'S ROWS while it shows nothing new — off in the title, standing still
  # in the lit scene — and feeds the kept ones again. Lit, off and lit again every four turns with
  # nothing moved, the picture is the interpreter's on every turn compared.
  def test_the_console_keeps_a_lights_rows_across_turns_and_still_frames
    taking_turns = program do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      mode = var :mode, 1
      turn = var :turn, 0
      spotlight at: [120, 80], radius: 40, dark: 100
      scene(:title) { layer(:water, transparency: 50) { background :pond, tiles: :set, map: ["r" * 32] * 32 } }
      scene(:playing) {}
      game_loop do
        turn.add! 1
        mode.set! 1 - ((turn >> 2) & 1)
        case_var(:mode) { when_val 0, :title; when_val 1, :playing }
      end
    end

    assert_backends_agree(taking_turns, frames: [2, 3, 5, 7, 9, 10, 13, 15], name: "KEPT")
  end
end
