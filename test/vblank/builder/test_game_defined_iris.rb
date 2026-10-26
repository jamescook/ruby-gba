# frozen_string_literal: true

require "test_helper"
require "midpoint_circle"

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
class TestGameDefinedIris < Minitest::Test
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

  # The console on every frame, in one run: each picture the console shows is the one the
  # interpreter shows after as many turns. Lined up on the turns the console finished, not its
  # frames, since it powers on and sets up before its first turn.
  def test_every_picture_on_the_console_is_the_interpreters
    require_emulator!
    interpreter = pictures(90).map(&:first)
    console = VBlank::Diagnostics::Verifier.new(assemble_rom(game, name: "OWNIRIS"), frames: 1, count_passes: true)
    compared = 0
    until (turns = console.step.passes) >= 89
      next if turns < 2

      assert_same_spans interpreter[turns], lit_spans(ConsolePicture.new(console.frame_gba)), "after turn #{turns}"
      compared += 1
    end

    assert_operator compared, :>=, 85, "the console showed a picture for nearly every turn"
  end

  # A picture read off the console, asked for a pixel the way the interpreter's screen is.
  ConsolePicture = Struct.new(:colors) do
    def pixel(x, y) = colors[(y * WIDTH) + x]
  end
end
