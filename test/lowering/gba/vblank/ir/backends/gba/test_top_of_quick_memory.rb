# frozen_string_literal: true

require "test_helper"

# WHAT THE BUILD HOLDS BACK AT THE TOP OF THE QUICK MEMORY: the console's own 256 bytes, the
# game's stack, and the divide routines when the game divides — and nothing else, since all of
# it is room the game's own variables, lists and code cannot have.
class TestTopOfQuickMemory < Minitest::Test
  include VBlank::IR::Build

  Top = GBA::TopOfQuickMemory
  HW = VBlank::Console::Hardware
  END_OF_QUICK = HW::IWRAM_START + HW::IWRAM_SIZE

  private def chain(depth)
    funcs = (1..depth).map { |level| func(:"step#{level}", level < depth ? call(:"step#{level + 1}") : set(:n, 1)) }
    program(*funcs, loop_(call(:step1)))
  end

  def test_a_game_that_does_not_divide_holds_back_only_the_consoles_room_and_its_stack
    top = Top.for(chain(3))

    assert_equal END_OF_QUICK - 256 - 1024, top.ceiling
    assert_nil top.divide_at
    assert_nil top.divide_fix_at
  end

  def test_the_divide_routines_sit_below_the_stack_at_their_own_size
    top = Top.for(chain(3), divides: true, divides_fractions: true)

    assert_equal END_OF_QUICK - 256 - 1024 - GBA::Divide::FIX_ROUTINE_BYTES, top.divide_fix_at
    assert_equal top.divide_fix_at - GBA::Divide::ROUTINE_BYTES, top.divide_at
    assert_equal top.divide_at, top.ceiling
  end

  def test_a_game_says_how_much_stack_room_it_wants
    assert_equal END_OF_QUICK - 256 - 512, Top.for(chain(3), stack_room: 512).ceiling
  end

  # --- through a real build ---

  # A GAME THAT NEVER DIVIDES GETS THE REST OF THE 32K: the console's 256 bytes and the stack are
  # all that is held back, where the whole top 4K used to be.
  def test_a_game_that_never_divides_has_all_but_the_stack_and_the_consoles_room
    rom = VBlank.build("ROOMY", console: :gba, out: StringIO.new, err: StringIO.new) do
      n = var :n, 0
      game_loop { n.add! 1 }
    end
    placement = rom.built.placement

    assert_equal HW::IWRAM_SIZE - 256 - 1024, placement.used_bytes + placement.free_bytes
  end

  def test_a_game_can_say_how_much_stack_room_it_wants
    rom = VBlank.build("STACKY", console: :gba, stack_room: 2048, out: StringIO.new, err: StringIO.new) do
      n = var :n, 0
      game_loop { n.add! 1 }
    end
    placement = rom.built.placement

    assert_equal HW::IWRAM_SIZE - 256 - 2048, placement.used_bytes + placement.free_bytes
  end

  # A CHAIN OF CALLS DEEPER THAN THE ROOM HOLDS GETS MORE, worked out from the program, so a game
  # that nests deeply never runs its stack into its own variables.
  def test_a_deep_chain_of_calls_gets_more_stack_room_than_the_usual
    shallow = Top.for(chain(3))
    deep = Top.for(chain(120))

    assert_operator deep.stack_bytes, :>, shallow.stack_bytes
    assert_equal 1024, shallow.stack_bytes
  end

  # ...and such a game still counts right on the console: three hundred routines deep, each adding
  # its own number, every frame — a stack well past the usual room, which the build gave it more of.
  DEEP = 300

  def test_a_deep_chain_of_calls_counts_right_on_the_console
    rom = VBlank.build("DEEPCALL", console: :gba, out: StringIO.new, err: StringIO.new) do
      total = var :total, 0
      func(:"level#{DEEP}") { total.add! DEEP }
      (1...DEEP).reverse_each do |level|
        func(:"level#{level}") do
          total.add! level
          call :"level#{level + 1}"
        end
      end
      game_loop { call :level1 }
    end
    v = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses, count_passes: true)

    assert_operator v.passes, :>, 0
    assert_equal (1..DEEP).sum * v.passes, v.var(:total)
  end

  # --- what a timer's handler calls ---

  # A TIMER'S HANDLER RUNS ON THE CONSOLE'S OWN INTERRUPT STACK, which ends where the game's stack
  # begins (see TopOfQuickMemory). A plain call costs four bytes there.
  PLAIN_CALL_BYTES = 4
  TICK_DEPTH = 40

  # A program whose timer's handler calls a chain of +depth+ routines.
  private def program_ticking(depth)
    chain = (1..depth).map { |level| func(:"tick#{level}", level < depth ? call(:"tick#{level + 1}") : set(:n, 1)) }
    program(*chain, timer_start(:beat, 60), on_timer(:beat, *(depth.zero? ? [set(:n, 1)] : [call(:tick1)])),
            loop_(set(:m, 1)))
  end

  def test_a_handler_that_calls_nothing_leaves_the_game_stack_where_the_console_puts_it
    assert_equal END_OF_QUICK - 256, Top.for(program_ticking(0)).stack_starts_at
  end

  def test_a_handler_that_calls_deep_starts_the_game_stack_lower_by_what_its_calls_need
    assert_operator Top.for(program_ticking(TICK_DEPTH)).stack_starts_at, :<=,
                    END_OF_QUICK - 256 - (TICK_DEPTH * PLAIN_CALL_BYTES)
  end

  # The game loop sits two routines deep, in a long counted loop, while a fast timer ticks: so its
  # return addresses are at the top of its stack whenever the handler runs.
  def test_a_handler_forty_routines_deep_leaves_the_game_running_on_the_console
    rom = VBlank.build("TICKDEEP", console: :gba, out: StringIO.new, err: StringIO.new) do
      var :hits, 0
      passes = var :passes, 0
      sum = var :sum, 0
      (1..TICK_DEPTH).each do |level|
        func(:"tick#{level}") { level == TICK_DEPTH ? add!(:hits, 1) : call(:"tick#{level + 1}") }
      end
      timer(:beat, per_second: 4000).on_tick { call :tick1 }
      func(:inner) { repeat(3000) { |i| sum.set! sum + i } }
      func(:outer) { call :inner }
      game_loop do
        call :outer
        passes.add! 1
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)

    assert_operator v.var(:passes), :>, 20, "the game loop kept finishing passes"
    assert_operator v.var(:hits), :>, 1000, "the handler kept answering ticks"
  end
end
