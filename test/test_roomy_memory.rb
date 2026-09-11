# frozen_string_literal: true

require "test_helper"

# THE OTHER WORK MEMORY, and what it is for.
#
# The console has two, and they are not two sizes of the same thing: a quick one of 32K on the
# processor's own die, and a roomy one of 256K on a chip of its own that makes the processor
# wait about six times as long for a whole number. Everything a program declared used to come
# out of the quick one, and a program asking for more than fits did not build — while a quarter
# of a megabyte sat idle, touched by nothing but the audio mixer's two output buffers.
#
# And the quick one is also where the hot code goes, so a big cold collection sitting there
# quietly pushes a routine the frame spends its time in out to the cartridge. That is the
# expensive half, and it is invisible from the program.
#
# What an author writes is nothing, nearly always. `fast: false` says "I know this is cold —
# give it room"; `fast: true` insists. It is the same word `func` already takes for the same
# question about code.
class TestRoomyMemory < Minitest::Test
  def build(title, &block)
    RubyGBA.build(title, code: "B#{title[0, 3]}", maker: "01",
                         out: StringIO.new, err: StringIO.new, &block)
  end

  def roomy_of(rom) = rom.built.roomy_memory

  # --- a game that used to fail to build ---

  # 32K is 8192 whole numbers, and the quick memory also holds the variables and the code kept
  # there — so three lists of 4000 cannot all be in it. They used to be a build failure.
  def test_more_state_than_the_quick_memory_holds_still_builds
    rom = build("BIG") do
      screen :bitmap
      big_a = list :big_a, capacity: 4000
      big_b = list :big_b, capacity: 4000
      big_c = list :big_c, capacity: 4000
      game_loop { big_a.push 1; big_b.push 2; big_c.push 3 }
    end

    assert_operator rom.size, :>, 0, "it builds"
    assert_operator roomy_of(rom).used, :>, 0, "and something went in the roomy memory"
  end

  # --- the choice is made from what a frame touches, not declaration order ---

  # The bug this exists to prevent: a cold collection declared FIRST taking the quick memory
  # and pushing the one a frame walks every pass into the memory that waits.
  def test_a_cold_list_declared_first_does_not_push_a_hot_one_out
    rom = build("ORDER") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1 # touched once, at boot, and never again
      game_loop { hot.push 2 }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold, "the one no frame touches moved"
    refute_includes moved, :hot, "and the one a frame walks stayed where reads are quick"
  end

  # A routine the frame calls counts as the frame touching it — otherwise a game that puts its
  # work in `func`s, which is every game of any size, would look entirely cold.
  def test_a_list_touched_from_a_routine_the_frame_calls_counts_as_hot
    rom = build("CALLED") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1
      func(:step) { hot.push 2 }
      game_loop { call :step }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold
    refute_includes moved, :hot, "reached through a call, so a frame touches it"
  end

  # A game of any size puts its per-frame work in SCENES, reached by a multi-way dispatch
  # rather than by a plain call. Following only calls reads such a game as entirely cold —
  # measured on a raycaster, all twenty-six of its collections came back untouched — which
  # would move the very things a frame walks into the memory that waits.
  def test_a_list_touched_from_a_scene_counts_as_hot
    rom = build("SCENE") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1
      var :state, 0
      scene(:playing) { hot.push 2 }
      game_loop { case_var(:state) { when_val 0, :playing } }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold
    refute_includes moved, :hot, "a scene is where a game's per-frame work lives"
  end

  # --- what the author can say ---

  def test_fast_false_gives_the_quick_memory_back
    rom = build("SAID") do
      screen :bitmap
      world = list :world, capacity: 64, fast: false
      game_loop { world.push 1 }
    end

    assert_includes roomy_of(rom).collections.keys, :world,
                    "it moved although there was plenty of room"
  end

  def test_fast_true_keeps_a_list_in_the_quick_memory
    rom = build("KEPT") do
      screen :bitmap
      cold = list :cold, capacity: 5000, fast: true
      other = list :other, capacity: 5000
      cold.push 1
      game_loop { other.push 2 }
    end

    refute_includes roomy_of(rom).collections.keys, :cold,
                    "the author insisted, so it stayed however cold it looks"
  end

  # A pool is one list per field, so it is the thing most likely to want this.
  def test_a_pool_can_be_given_room
    rom = build("POOL") do
      screen :bitmap
      pool :spark, x: 0, y: 0, life: 0, capacity: 64, fast: false
      game_loop {}
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :__pool_spark_x, "every one of its columns moved together"
    assert_includes moved, :__pool_spark_life
  end

  # --- and it has to actually work ---

  # The one that matters: a list in the roomy memory is read and written like any other, and
  # the program comes out with the right answer. Held on both backends, since the interpreter
  # has one memory and the console has two — so agreeing means the addresses are right.
  def counting_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      far = list :far, capacity: 5000, fast: false
      total = var :total, 0
      clear_screen :black
      repeat(8) { far.push 3 }
      repeat(8) { |n| total.add far[n] }
      # A stripe as wide as the total, so the console can be asked what it read back.
      draw_rect_at 0, 10, total, 4, :green
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_list_in_the_roomy_memory_holds_what_was_put_in_it
    assert_equal 24, Reference.new.run(counting_program)[:total]
  end

  # The counting program paints a stripe as wide as the total it read back, so the console
  # says the same number the oracle does — through a list the console keeps in its other
  # memory and the oracle keeps in a Ruby array.
  def test_the_console_reads_it_back_the_same
    rom = ROM.assemble(GBA.new.lower(counting_program), title: "FARLIST", code: "BFAR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    assert v.pixel_is?(23, 10, :green), "24 pixels of stripe, so the total came back as 24"
    assert v.pixel_is?(24, 10, :black), "...and no more than 24"
  end

  # --- what the build says about it ---

  def test_the_report_names_what_moved_and_how_much_room_is_left
    rom = build("SAYS") do
      screen :bitmap
      world = list :world, capacity: 4096, fast: false
      game_loop { world.push 1 }
    end

    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)
    printed = out.string
    assert_match(/roomy memory/, printed)
    assert_match(/:world/, printed, "it names what moved")
    assert_match(/waits/, printed, "and says what that costs")
  end

  # A game whose state fits reads nothing about a second memory it never met.
  def test_a_game_that_fits_says_nothing_about_it
    rom = build("SMALL") do
      screen :bitmap
      small = list :small, capacity: 8
      game_loop { small.push 1 }
    end

    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)
    refute_match(/roomy memory/, out.string)
  end
end
