# frozen_string_literal: true

require "test_helper"

# `rumble frames:, pattern:` — the player's hands shaken, as a ball hitting a bumper shakes them:
# the cartridge's motor run on or off on each frame by the pattern's eight frames, for as many
# frames as the game said. Felt only on a console whose cartridge carries a motor, the Color's;
# on any other the game plays the same and nothing is felt.
class TestRumble < Minitest::Test
  # A game that rumbles in +pattern+ for +frames+ frames on its second pass, and halts on +halt+.
  private def bumped(frames: 10, pattern: "##..#.#.", halt: nil)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 2).then { rumble frames: frames, pattern: pattern }
        (pass == halt).then { self.halt } if halt
      end
    end
    b.finalize_program
    b.program
  end

  # The motor on each of the first +frames+ frames the game shows, as "#" and ".".
  private def felt(program, frames: 16)
    player = game_player
    seen = +""
    player.each_vblank { seen << (player.motor_on? ? "#" : ".") }.run(program, frames: frames)
    seen
  end

  # +pattern+ where this run's console has a motor, and nothing felt where it has none.
  private def felt_here(pattern)
    VBlank::Console.described(game_console).rumbles ? pattern : "." * pattern.length
  end

  def test_the_motor_runs_the_pattern_round_for_the_frames_said
    # Said in the second pass, so the motor starts as the third frame shows; ten frames of the
    # pattern, round again after its eighth, then still.
    assert_equal felt_here("..##..#.#.##...."), felt(bumped)
  end

  def test_steady_is_on_for_every_frame_said
    assert_equal felt_here("..######........"), felt(bumped(frames: 6, pattern: 0xFF))
  end

  # A number is read as the Color's own games read theirs: Pokémon Pinball's 0x05, its bits 0 and
  # 2, runs on its pattern's second and eighth frames.
  def test_a_number_plays_as_the_colors_own_games_play_it
    assert_equal felt_here("...#.....#......"), felt(bumped(frames: 8, pattern: 0x05))
  end

  def test_a_game_that_halts_shakes_nothing_more
    player = game_player
    player.run(bumped(frames: 100, halt: 5), frames: 16)

    refute player.motor_on?
    assert_equal 5, player[:pass]
  end

  def test_a_pattern_that_is_not_eight_frames_is_refused
    error = assert_raises(ArgumentError) { bumped(pattern: "##.") }
    assert_match(/8 frames/, error.message)
    assert_raises(ArgumentError) { bumped(pattern: 256) }
  end

  def test_frames_out_of_range_are_refused
    error = assert_raises(ArgumentError) { bumped(frames: -1) }
    assert_match(/not from 0 to 65535/, error.message)
    assert_raises(ArgumentError) { bumped(frames: 70_000) }
  end
end
