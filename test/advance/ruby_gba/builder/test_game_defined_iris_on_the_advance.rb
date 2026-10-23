# frozen_string_literal: true

require "test_helper"
require "differential"
require "midpoint_circle"

# The tests of test_game_defined_iris.rb whose games put a light on the screen — a circle of
# picture with dark round it — which a Game Boy Color's hardware cannot do, so they play on the
# Advance's runs alone.
#
# AN EFFECT A GAME WRITES FOR ITSELF, on nothing but what any game can use: The Minish Cap's iris,
# copied as a pack the game brings in with `uses`. The framework knows nothing about it. The pack
# gives the light the game's own shape — each row the midpoint circle of the row above, as that game
# hands its rows over — and walks it with a job a pass, the way that game counts.
#
# Measured on the real cartridge (frames from the game's own count): the closing circle is 146 at
# the end of the frame it starts, 4 less every frame to 2, then 0; centred on (120, 80). The opening
# one is 4 on the frame it starts, 4 more every frame, centred on (184, 96), and the light goes once
# it passes 150. Each size is drawn on the next picture — but the opening's first, which that game
# hands the console while the picture is drawn, so it shows on the picture of the turn it starts.
class TestGameDefinedIrisOnTheAdvance < Minitest::Test
  include Differential
  include MidpointCircle

  # The pack, as a game would write it.
  module CopiedIris
    def close_iris(at:)
      light = copied_iris_light
      light.move_to(*at)
      light.dark.set! 100
      light.radius.set! 150
      each_pass(:copied_iris_closing).start
    end

    def open_iris(at:)
      light = copied_iris_light
      light.move_to(*at)
      light.dark.set! 100
      light.radius.set! 0
      each_pass(:copied_iris_opening).start
      light.show_now # that game hands the console its first circle as it asks for it
    end

    def iris_closed? = (spotlight.radius == 0) & (spotlight.dark == 100)

    private

    # The light, given its shape and its two walks the first time a verb asks for it.
    def copied_iris_light
      return spotlight if @copied_iris_ready

      @copied_iris_ready = true
      light = spotlight
      light.shape do |row|
        half = light.circle((row - 1).clamp(0, 159))
        [light.x - half, light.x + half]
      end
      each_pass(:copied_iris_closing) do |job|
        light.radius.sub! 4
        (light.radius <= 0).then do
          light.radius.set! 0
          job.stop
        end
      end
      each_pass(:copied_iris_opening) do |job|
        light.radius.add! 4
        (light.radius > 150).then do
          light.dark.set! 0
          job.stop
        end
      end
      light
    end
  end

  # The turns the walks start on: closing on turn 3, opening on turn 45.
  CLOSES = 3
  OPENS = 45

  private def game
    b = Builder.new
    b.instance_eval do
      uses CopiedIris
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      turn = var :turn, 0
      closed = var :closed, 0
      game_loop do
        turn.add! 1
        (turn == CLOSES).then { close_iris at: [120, 80] }
        (turn == OPENS).then { open_iris at: [184, 96] }
        iris_closed?.then { closed.set! 1 }.else { closed.set! 0 }
      end
    end
    b.finalize_program
    b.program
  end

  # Every picture of a run, as each row's lit span, and whether the iris said it was closed. The
  # first is read before turn 1, so entry n is read at the end of turn n — and its picture is drawn
  # from turn n - 1, since a size set in a turn is drawn on the next picture.
  private def pictures(frames)
    seen = []
    run = game_player
    run.each_vblank { seen << [lit_spans(run.screen), run[:closed]] }
    run.run(game, frames: frames)
    seen
  end

  # The size the copied game's light holds at the end of +turn+, or nil for a light letting the
  # whole picture show.
  private def size_after(turn)
    if turn < CLOSES then nil
    elsif turn < OPENS then [150 - (4 * (turn - CLOSES + 1)), 0].max
    elsif (opened = 4 * (turn - OPENS + 1)) <= 150 then opened
    end
  end

  def test_every_row_of_every_picture_is_the_copied_games
    seen = pictures(90)

    (2...90).each do |picture|
      turn = picture == OPENS ? OPENS : picture - 1 # the opening's first size is shown at once
      size = size_after(turn)
      expected = if size.nil? then Array.new(HEIGHT) { [0, WIDTH] }
                 else game_circle_spans_a_row_late(turn < OPENS ? 120 : 184, turn < OPENS ? 80 : 96, size)
                 end
      assert_same_spans expected, seen[picture].first, "picture #{picture}, after turn #{turn} (size #{size.inspect})"
    end
  end

  def test_it_says_closed_from_the_turn_the_size_is_nought
    seen = pictures(46)
    nought = CLOSES + (150 / 4) # 146 on turn 3 ... 2 on turn 39, nought on turn 40

    assert_equal 0, seen[nought - 1].last, "turn #{nought - 1}: not yet"
    assert_equal 1, seen[nought].last, "turn #{nought}: closed"
  end

  # On the native and JavaScript runs this plays the game there and checks it against the
  # interpreter on every frame. On the GBA run it asks the console at a few moments: the closing
  # walk, the shut light, and the opening one.
  def test_the_console_and_every_other_backend_draw_the_same_rows
    assert_backends_agree(game, frames: [4, 20, 41, 46, 70, 84, 88], name: "OWNIRIS")
  end
end
