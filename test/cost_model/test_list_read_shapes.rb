# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# A LIST READ IS TWO PRICES, and the shape of the read decides which. A plain list read by
# the loop's own counter — a pool's live test, a list's `each` — has no index to load, no head
# to add and no mask to apply, and the console reads it at a fraction of the general read. A
# read by a variable in memory, or of a ring (a list the program shifts), pays the whole thing.
#
# Priced at the general weight, a pool's whole walk read a third over the console; these pin
# which weight each shape is priced through, by moving one weight and watching what follows.
class TestListReadShapes < CostModelTest
  SLOTS = 64

  # Built cartridges rather than bare programs, because which shape a loop got — whether
  # its counter stays in a register — is the build's answer, and a model with no build
  # behind it takes the safe shape, through memory, where no read is by a counter.
  def walk_by_counter(code, shifted: false)
    RubyGBA.build("SHAPES", code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      t = var :t, 0
      live = list :live, capacity: SLOTS
      SLOTS.times { live << 0 }
      if shifted
        live.shift
        live << 0
      end
      game_loop { repeat(SLOTS) { |i| (live[i] == 1).then { t.add 1 } } }
    end
  end

  def walk_by_variable
    RubyGBA.build("SHAPES", code: "ZLRV", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      t = var :t, 0
      j = var :j, 3
      live = list :live, capacity: SLOTS
      SLOTS.times { live << 0 }
      game_loop { repeat(SLOTS) { |_i| (live[j] == 1).then { t.add 1 } } }
    end
  end

  # Whether +weight+ is what the cartridge's list reads are priced through: move it a long
  # way and see whether the frame follows.
  def priced_through?(rom, weight)
    program = rom.source_program
    plain = rom.cost_model.steady_cost(program)
    rom.cost_model(weight => 1.0).steady_cost(program) > plain + 10
  end

  def test_a_plain_list_read_by_the_loops_own_counter_is_the_cheap_read
    prog = walk_by_counter("ZLRC")

    assert priced_through?(prog, :list_read_in_walk)
    refute priced_through?(prog, :list_read)
  end

  def test_a_read_by_a_variable_in_memory_is_the_general_read
    prog = walk_by_variable

    assert priced_through?(prog, :list_read)
    refute priced_through?(prog, :list_read_in_walk)
  end

  # A ring has a head to add and a mask to apply whatever indexes it, so the counter buys
  # nothing there.
  def test_a_ring_read_by_the_counter_is_still_the_general_read
    prog = walk_by_counter("ZLRR", shifted: true)

    assert priced_through?(prog, :list_read)
    refute priced_through?(prog, :list_read_in_walk)
  end

  # A walk whose body drops to raw instructions keeps its counter in memory (nothing can be
  # bracketed around an escape hatch), so the counter is loaded before the element is
  # reached — the walk's other price.
  def test_a_walk_whose_counter_lives_in_memory_is_the_walks_other_price
    rom = RubyGBA.build("SHAPES", code: "ZLRM", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      t = var :t, 0
      live = list :live, capacity: SLOTS
      SLOTS.times { live << 0 }
      game_loop do
        repeat(SLOTS) do |i|
          entry {}
          (live[i] == 1).then { t.add 1 }
        end
      end
    end

    assert priced_through?(rom, :list_read_in_walk_memory)
    refute priced_through?(rom, :list_read_in_walk)
    refute priced_through?(rom, :list_read)
  end

  # The regimes are measured, not derived: the walk's reads really are cheaper than the
  # general one, and the register-kept counter cheaper than the one in memory.
  def test_the_walks_reads_are_cheaper_than_the_general_one
    assert_operator WEIGHTS[:list_read_in_walk], :<, WEIGHTS[:list_read_in_walk_memory]
    assert_operator WEIGHTS[:list_read_in_walk_memory], :<, WEIGHTS[:list_read]
  end
end
