# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT `late:` BOUGHT AND WHAT IT COST, said in the profile a game reads: the late pages a
# tear-free screen showed at once, and how many of those were shown part way down the picture,
# where they can tear. Counted by how many times the instruction that shows one ran, so the
# cartridge carries nothing extra to be counted. (When the console shows them is
# test/vblank/ir/backends/gba/test_late_pages.rb's.)
class TestLatePagesShown < Minitest::Test
  include EmulatorSupport

  # Passes a little over a frame long, measured to end a few rows down the picture, and during
  # the break between pictures.
  ENDS_NEAR_THE_TOP = 29_700
  ENDS_IN_THE_BREAK = 22_600

  private def profile(late, work: ENDS_NEAR_THE_TOP)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, late: late
      done = var :done, 0
      game_loop do
        clear_screen :gray
        repeat(work) { done.add! 1 }
      end
    end
    b.finalize_program
    backend = GBA.new
    machine_code = backend.lower(b.program)
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: "LATESAY", built: backend.build_record(b.program))
    VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
  end

  private def said(result)
    out = StringIO.new
    VBlank::Diagnostics::Profiler.render(result, out: out)
    out.string
  end

  def test_the_profile_says_how_many_late_pages_it_showed_and_how_many_can_tear
    require_emulator!
    result = profile(:show_now)

    assert_match(/#{result.pages_shown_at_once} pages were late and shown at once/, said(result))
    assert_match(/#{result.pages_shown_part_way} of them were shown part way down the picture/, said(result))
    assert_equal result.pages_shown_at_once, result.to_h[:pages_shown_at_once]
  end

  # Shown only in the break, nothing tore, and the profile says so rather than "0 of them".
  def test_pages_all_shown_in_the_break_are_said_to_be_shown_where_nothing_tears
    require_emulator!
    words = said(profile(4, work: ENDS_IN_THE_BREAK))

    assert_match(/All of them were shown between pictures/, words)
    refute_match(/part way down/, words)
  end

  def test_a_screen_that_waits_says_nothing_about_it
    require_emulator!

    refute_match(/shown at once/, said(profile(:wait)))
  end
end
