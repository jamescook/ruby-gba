# frozen_string_literal: true

require "test_helper"

# WHAT A GAME COSTS BEFORE ITS FIRST FRAME, on the console. A collection is made full at power-on
# — a pool's slots, a list the game declares `full_of:` — and making it full is work the first
# pass pays for, before the game has drawn anything. A pass that ends after its frame shows the
# game's first picture a frame late, so a bigger pool must not cost a slot's worth of work per
# field.
class TestPowerOnCost < Minitest::Test
  # The instructions the first frame ran for a pool of +slots+ with a dozen fields, the shape
  # of a game's things. Counted only when power-on and the first pass fit that frame with time
  # over: a frame that ran out of time stops counting at its end, and two that both did would
  # read the same however different their work.
  private def power_on_instructions(slots)
    rom = RubyGBA.build("POWERON", out: StringIO.new, err: StringIO.new, profile: false) do
      fields = (1..12).to_h { |n| [:"f#{n}", 0] }
      things = pool :things, capacity: slots, **fields
      game_loop { things.each { |thing| thing.f1.add! 1 } }
    end
    result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 1, settle: 0, picture: false)
    assert_operator result.idle_share, :>, 0, "power-on with #{slots} slots used the whole first frame"
    result.samples
  end

  def test_one_more_pool_slot_costs_little_at_power_on
    require_emulator!
    more = power_on_instructions(41) - power_on_instructions(40)

    assert_operator more, :<, 60, "one more slot of a twelve-field pool cost #{more} instructions at power-on"
  end
end
