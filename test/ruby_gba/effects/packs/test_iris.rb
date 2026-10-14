# frozen_string_literal: true

require "test_helper"
require "differential"

# The iris: a circle that closes on a point until the screen is black, and opens again.
#
# It is the game's own light walked over frames, so what is asserted is the walk: shut at
# the end of the frames asked for, open again at the end of the way back, part way between
# on both backends alike — and a lantern the game had given back as it was.
class TestIris < Minitest::Test
  include Differential

  WHITE = Color.resolve(:white)
  BLACK = Color.rgb(0, 0, 0)

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A white room; +before+ runs before the loop, +each+ inside it.
  def room(before: nil, each: nil)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      instance_exec(&before) if before
      game_loop { instance_exec(&each) if each }
    end
  end

  def shown(program, frames:) = Reference.new.run(program, frames: frames).screen

  def all_one_color?(screen, color)
    (0...160).step(8).all? { |y| (0...240).step(8).all? { |x| screen.pixel(x, y) == color } }
  end

  # A walk of ten frames, said before the loop, arrives on the tenth.
  def closing = room(before: -> { iris_out at: [60, 40], frames: 10 })

  def test_an_iris_out_closes_until_the_screen_is_black
    refute all_one_color?(shown(closing, frames: 4), BLACK), "part way in, some of the room still shows"
    assert all_one_color?(shown(closing, frames: 14), BLACK), "and at the end none of it does"
  end

  def test_it_closes_on_the_point_it_was_given
    screen = shown(closing, frames: 7)

    assert_equal WHITE, screen.pixel(60, 40), "the point is the last of the room to go"
    assert_equal BLACK, screen.pixel(230, 150), "the far corner went first"
  end

  def test_the_console_closes_the_same_circle
    assert_backends_agree(closing, frames: 5)
  end

  # Swap what is drawn while the screen is black, then open: the way a scene changes.
  def test_an_iris_in_opens_it_again_and_shut_says_when
    swapped = room(before: -> { iris_out frames: 6 },
                   each: lambda {
                     gone = var :gone, 0
                     iris_shut?.then do
                       gone.set! 1
                       iris_in frames: 6
                     end
                   })
    reached = Reference.new.run(swapped, frames: 9)

    assert_equal 1, reached[:gone], "the circle shut"
    assert all_one_color?(shown(swapped, frames: 30), WHITE), "and opened back to the room as drawn"
    assert_backends_agree(swapped, frames: 30)
  end

  # A game with a lantern gets its lantern back: as big and as dark as it was.
  def test_a_lantern_is_given_back_as_it_was
    lantern = room(before: lambda {
                     spotlight at: [120, 80], radius: 40, dark: 75
                     iris_out frames: 4
                   },
                   each: -> { iris_shut?.then { iris_in frames: 4 } })
    screen = shown(lantern, frames: 20)

    assert_equal WHITE, screen.pixel(120, 80)
    assert_equal Color.rgb(8, 7, 7), screen.pixel(5, 5), "outside it is as dark as before"
    assert_backends_agree(lantern, frames: 20)
  end

  # ...unless the way back says otherwise: out of the dark and into daylight.
  def test_an_iris_in_can_open_to_another_light
    daylight = room(before: lambda {
                      spotlight at: [120, 80], radius: 40, dark: 75
                      iris_out frames: 4
                    },
                    each: -> { iris_shut?.then { iris_in frames: 4, dark: 0 } })

    assert all_one_color?(shown(daylight, frames: 20), WHITE)
    assert_backends_agree(daylight, frames: 20)
  end

  # Opening onto a light that darkens nothing, the circle goes on opening until it is past
  # the corners, rather than stopping at the size the lantern was and the rest of the
  # picture appearing at once.
  def test_opening_onto_daylight_opens_across_the_whole_screen
    daylight = room(before: lambda {
                      spotlight at: [120, 80], radius: 20, dark: 75
                      iris_out frames: 4
                    },
                    each: -> { iris_shut?.then { iris_in frames: 20, dark: 0 } })
    part_way = shown(daylight, frames: 18)

    assert_equal WHITE, part_way.pixel(120 + 45, 80), "part way open, the circle is already past the lantern's size"
    assert_equal BLACK, part_way.pixel(5, 5), "and not yet at the corners"
  end

  # A game that opens on an iris says `iris_in` with nothing closed before it: the screen
  # starts black and the circle opens.
  def test_an_iris_in_with_nothing_closed_opens_from_black
    opening = room(before: -> { iris_in frames: 20 })

    assert_equal BLACK, shown(opening, frames: 2).pixel(20, 20), "it starts closed"
    assert all_one_color?(shown(opening, frames: 30), WHITE), "and opens onto the room"
  end

  # The walk starts at about the farthest corner, so the very first frames already close.
  def test_the_circle_is_seen_closing_from_the_first_frames
    early = shown(room(before: -> { iris_out at: [120, 80], frames: 20 }), frames: 4)

    assert_equal BLACK, early.pixel(0, 0), "a corner has gone after three frames of twenty"
  end

  def test_an_iris_out_never_brought_back_is_a_warning
    out = StringIO.new
    err = StringIO.new
    RubyGBA.build("IRIS", out: out, err: err) do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      iris_out
      game_loop {}
    end

    assert_match(/never calls `iris_in`/, out.string + err.string)
  end

  def test_a_light_declared_after_an_iris_is_refused
    error = assert_raises(ArgumentError) do
      room(before: lambda {
        iris_out
        spotlight at: [10, 10], radius: 20
      })
    end

    assert_match(/before the first `iris_out`/, error.message)
  end
end
