# frozen_string_literal: true

require "test_helper"
require "stringio"

require_relative "../examples/sparks"

# The sparks example: a pool of particles walked every frame on a bitmap screen — the one
# example whose frame IS a pool walk, so the corpus tools (rake cost:check, cost:ranking,
# cost:regimes) reach the walk's own regimes. These assert BEHAVIOUR: sparks appear and
# fall, on the interpreter and on the console.
class TestSparksExample < Minitest::Test
  YELLOW = Color.resolve(:yellow)

  def yellow_rows(screen)
    (0...160).select { |y| (0...240).any? { |x| screen.pixel(x, y) == YELLOW } }
  end

  def test_sparks_appear_and_fall_down_the_screen
    early = yellow_rows(Reference.new.run(Sparks.program, frames: 4).screen)
    later = yellow_rows(Reference.new.run(Sparks.program, frames: 40).screen)

    refute_empty early, "sparks are drawn"
    assert_operator later.max, :>, early.max, "and they fall"
    assert_operator later.length, :>, early.length, "with more of them alive as frames go by"
  end

  # A full pool recycles its oldest and a spark that leaves the bottom gives its slot back,
  # so the shower never stops: long after every slot has been used, sparks are still there.
  def test_the_shower_keeps_going_once_every_slot_has_been_used
    screen = Reference.new.run(Sparks.program, frames: Sparks::SLOTS * 4).screen

    refute_empty yellow_rows(screen)
  end

  def test_the_console_draws_the_shower_too
    rom = Sparks.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_gemba_loads_rom(rom, frames: 30)

    assert v.frame_gba.include?(YELLOW), "a spark is on the console's screen"
  end
end
