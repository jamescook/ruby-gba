# frozen_string_literal: true

require "test_helper"

# WHERE THE TIME GOES INSIDE A ROUTINE TOO BIG FOR THE QUICK MEMORY.
#
# A routine is kept in the console's quick memory whole or not at all, and one that grows past
# the room runs entirely from the cartridge — though most of its time is usually spent in a
# small part of it, and that part would fit. The build does not take a game's routine apart on
# its own; the profile says which part to make a `func` of, by the line that wrote it, and
# whether that part would fit.
class TestSplitHints < Minitest::Test
  # A game loop too big for the quick memory, because of a block that never runs, with a small
  # loop in it that runs every frame. Answers the program and the busy loop's line.
  private def big_loop_with_a_busy_part
    busy = nil
    builder = Builder.new
    builder.instance_eval do
      x = var :x, 0
      y = var :y, 0
      game_loop do
        (x == 99_999).then { 2400.times { x.add! 1 } }
        busy = __LINE__ + 1
        repeat(300) { y.add! 1 }
      end
    end
    builder.finalize_program
    [builder.program, busy]
  end

  def test_the_profile_names_the_busy_part_of_a_routine_that_did_not_fit
    program, busy = big_loop_with_a_busy_part
    rom = assemble_rom(program, name: "SPLIT")
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 10, picture: false)
    hint = result.split_hints.first

    refute_nil hint, "a routine that did not fit and does the frame's work gets a hint"
    assert_equal VBlank::Cartridge::BuildRecord::FRAME_ROUTINE, hint.routine
    assert hint.source.end_with?("test_split_hints.rb:#{busy}"), "it names the busy loop, not #{hint.source}"
    assert_operator hint.share, :>, 50, "which holds most of the routine's time"
    assert hint.fits, "and is small enough to keep in the quick memory as a func"
  end

  # The report says it in the words an author acts on: the line, and to make it a func.
  def test_the_printed_profile_says_which_line_to_make_a_func_of
    program, busy = big_loop_with_a_busy_part
    rom = assemble_rom(program, name: "SPLIT")
    out = StringIO.new
    VBlank::Diagnostics::Profiler.render(VBlank::Diagnostics::Profiler.run(rom, frames: 10, picture: false), out: out)

    assert_match(/test_split_hints\.rb:#{busy}, in the game loop: .*% of that code's time/, out.string)
    assert_match(/put this code in a `func`/, out.string)
  end

  # A routine that missed but does next to nothing a frame has a busiest part too, and naming it
  # buys nothing: a game asleep most of the frame is not told to make a `func` of one compare.
  def test_a_routine_that_missed_and_does_little_gets_no_hint
    builder = Builder.new
    builder.instance_eval do
      x = var :x, 0
      game_loop { (x == 99_999).then { 2400.times { x.add! 1 } } }
    end
    builder.finalize_program
    result = VBlank::Diagnostics::Profiler.run(assemble_rom(builder.program, name: "IDLE"), frames: 10, picture: false)

    assert_empty result.split_hints
  end

  # A PART IS PICKED BY THE ROOM IT WOULD HAVE ITSELF. The room a `func` gets includes the
  # routines kept that the run spent less time in, so a quieter part has less room than a busier
  # one: here the busy part A (5K) and the quieter part B (3K) both outgrow what each would get,
  # and the hint names A, saying it does not fit — not B, picked by A's room and then said not to.
  def test_a_part_is_said_to_fit_only_in_the_room_it_would_have
    cartridge = 0x0800_0000
    parts = [{ source: "game.rb:10", at: cartridge...(cartridge + 5120) },
             { source: "game.rb:20", at: (cartridge + 5120)...(cartridge + 8192) }]
    placement = Struct.new(:funcs, :sizes, :free_bytes).new([:kept], { kept: 2048 }, 1536)
    built = Struct.new(:missed_routine_parts, :routines, :placement, :scene_sets)
                  .new({ big: parts }, { big: cartridge...(cartridge + 8192), kept: 0x0300_0000...0x0300_0800 }, placement, nil)
    profile = Struct.new(:cycles, :frames, :cycles_per_frame)
                    .new({ cartridge => 10_000, cartridge + 5120 => 6000, 0x0300_0000 => 8000 }, 1, 280_896)
    hints = VBlank::Diagnostics::SplitHints.of(profile, Struct.new(:built).new(built))

    assert_equal "game.rb:10", hints.first.source
    refute hints.first.fits
    assert(hints.all? { |hint| hint.fits == (hint.bytes <= hint.room) })
  end

  # A game whose routines all fit has nothing to split, and says nothing about it.
  def test_a_game_whose_routines_all_fit_gets_no_hint
    builder = Builder.new
    builder.instance_eval do
      y = var :y, 0
      game_loop { repeat(300) { y.add! 1 } }
    end
    builder.finalize_program
    result = VBlank::Diagnostics::Profiler.run(assemble_rom(builder.program, name: "FITS"), frames: 10, picture: false)

    assert_empty result.split_hints
  end
end
