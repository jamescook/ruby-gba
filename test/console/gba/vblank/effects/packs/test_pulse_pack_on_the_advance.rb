# frozen_string_literal: true

require "test_helper"
require "all/vblank/effects/packs/test_pulse_pack"

# The tests of test_pulse_pack.rb that play a pulse: a sprite that grows, shrinks and keeps doing
# it. A pulse resizes the sprite with `sprite.scale`, and neither a Game Boy Color nor a Super
# Nintendo can resize a sprite, so these play on the Advance's runs alone. They assert what a
# player sees — the sprite is bigger part-way through the cycle than it started, back near its
# starting size by the end of it, and off again after that. The friendly errors are in
# test/all/vblank/effects/packs/test_pulse_pack.rb.
class TestPulsePackOnTheAdvance < Minitest::Test
  include PulsePackGames

  # One second, so half a cycle is 30 frames and the numbers below are easy to place.
  HALF = 30

  # The sprite's size after +frames+ frames, as the multiple the author writes.
  private def size_after(frames, **opts)
    interpreter = game_player.run(pulse_program(frames, **opts), max_steps: 50_000_000)
    interpreter[:__obj1_scale] / VBlank::IR::Build::SCALE_ONE.to_f
  end

  # --- it breathes ---

  # Part-way up the climb the sprite is bigger than it started but not yet at the top.
  def test_it_is_part_way_grown_part_way_through_the_climb
    size = size_after(HALF / 2)
    assert_operator size, :>, 1.1
    assert_operator size, :<, 1.5
  end

  # It reaches the size that was asked for, rather than stopping a little short.
  def test_it_reaches_the_size_it_was_asked_for
    assert_in_delta 1.5, size_after(HALF - 1), 0.01
  end

  # ...and comes back down. By the end of the cycle it is near where it began.
  def test_it_shrinks_back_by_the_end_of_the_cycle
    assert_in_delta 1.0, size_after(HALF * 2), 0.05
  end

  # And then goes again — a pulse repeats rather than running once.
  def test_it_goes_again_on_the_next_cycle
    assert_in_delta size_after(HALF / 2), size_after((HALF * 2) + (HALF / 2)), 0.05
  end

  # A pulse can breathe around a size, not only up from one.
  def test_it_can_start_smaller_than_the_drawn_size
    assert_in_delta 0.8, size_after(1, from: 0.8, to: 1.2), 0.02
    assert_operator size_after(HALF - 1, from: 0.8, to: 1.2), :>, 1.1
  end
end
