# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# A CALL PICKED BY NUMBER: `call [:op_end, :op_wait, ...], number: opcode`.
#
# The number comes out of data — the instruction byte of a script read from a cartridge, the
# state kept on one of thirty guards — and what it picks is a routine. The point of it is that
# it costs the same however many routines there are, where asking "is it this one?" of each in
# turn costs a test per routine, all of them every time.
#
# So this file has two halves: that it picks the RIGHT routine (on both backends, from a
# variable, from a pooled instance's own field, and inside a loop), and that what it costs does
# not grow with the length of the list.
class TestCallOneOf < Minitest::Test
  include Differential

  # A script format's worth of instructions — the size the real case is.
  MANY = 139

  # How many dispatches a frame the measuring programs make.
  DISPATCHES = 16

  def program_with(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- it picks the right routine ---

  def test_the_number_picks_which_routine_runs
    interpreted = run_picking(2)

    assert_equal 33, interpreted[:n], "the number is a place in the list, counting from 0"
  end

  def test_the_first_routine_is_number_nought
    assert_equal 11, run_picking(0)[:n]
  end

  # A number past the end of the list names no routine, so nothing is called — the same answer
  # `show_map` and a song list give a number that names nothing. A game reading a number out of
  # data needs no test around it.
  def test_a_number_past_the_end_calls_nothing
    assert_equal 0, run_picking(3)[:n]
  end

  def test_a_number_below_nought_calls_nothing
    assert_equal 0, run_picking(-1)[:n]
  end

  # The number may be worked out where it is written, not only read out of a variable.
  def test_the_number_can_be_worked_out_on_the_spot
    program = program_with do
      screen :bitmap
      n = var :n, 0
      step = var :step, 1
      b = self
      b.func(:first) { n.set 11 }
      b.func(:second) { n.set 22 }
      b.func(:third) { n.set 33 }
      game_loop { b.call %i[first second third], number: step + 1 }
    end

    assert_equal 33, Reference.new.run(program)[:n]
  end

  # THE CASE THE FEATURE IS FOR: each instance of a pool carries its own number, so one line
  # inside `each` runs a different routine for every one of them.
  def test_each_pooled_instance_picks_its_own_routine
    program = program_with do
      screen :bitmap
      walked = var :walked, 0
      waited = var :waited, 0
      scripts = pool :script, step: 0, capacity: 4
      b = self
      b.func(:op_walk) { walked.add 1 }
      b.func(:op_wait) { waited.add 1 }
      scripts.spawn(step: 0)
      scripts.spawn(step: 1)
      scripts.spawn(step: 1)
      game_loop do
        scripts.each { |s| b.call %i[op_walk op_wait], number: s.step }
        b.halt
      end
    end
    interpreted = Reference.new.run(program)

    assert_equal 1, interpreted[:walked]
    assert_equal 2, interpreted[:waited]
  end

  # --- and the console agrees ---

  # Each routine paints its own rectangle, so which one ran is on the screen. Every pixel of
  # both backends' pictures has to match.
  def test_both_backends_draw_what_the_number_picked
    assert_backends_agree(drawing_program, frames: 3)
  end

  # THE TABLE HOLDS WHERE EACH ROUTINE REALLY RUNS, which is not the same place for all of
  # them: one kept in the console's quick memory was copied there at boot, and one left in the
  # cartridge never moves. Both are reached through the same table, so a build that wrote the
  # cartridge's address for the moved routine would jump into whatever else was there.
  def test_a_routine_in_the_quick_memory_and_one_in_the_cartridge_are_both_reached
    rom = RubyGBA.build("PICKFAST", code: "BPK2", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      moved = var :moved, 0
      left = var :left, 0
      here = var :here, 0
      there = var :there, 1
      b = self
      b.func(:in_quick_memory, fast: true) { moved.add 1 }
      b.func(:in_cartridge, fast: false) { left.add 1 }
      game_loop do
        b.call %i[in_quick_memory in_cartridge], number: here
        b.call %i[in_quick_memory in_cartridge], number: there
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_operator v.var(:moved), :>, 0, "the routine kept in the quick memory was reached"
    assert_operator v.var(:left), :>, 0, "...and so was the one left in the cartridge"
  end

  # A LIST TOO LONG FOR ITS LENGTH TO RIDE INSIDE AN INSTRUCTION. The console can carry a
  # number up to 255 in the compare that holds the call back, and a longer list has to put its
  # length in a register first. 257 is the first length that needs it.
  def test_a_list_longer_than_a_number_can_ride_in_an_instruction
    names = (0...257).map { |i| :"op#{i}" }
    rom = RubyGBA.build("PICKLONG", code: "BPK4", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = var :n, 0
      last = var :last, 256
      past = var :past, 257
      names.each_with_index { |name, i| func(name) { n.set i } }
      b = self
      game_loop do
        b.call names, number: last
        b.call names, number: past
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal 256, v.var(:n), "the last routine of 257 ran, and the number past the end called nothing"
  end

  # ...and the address in the table is where the routine REALLY runs. A routine kept in the
  # quick memory is also left in the cartridge, where boot copied it from, and that copy runs
  # perfectly well — about two and a half times slower. So calling the wrong one of the two is
  # not a broken game, it is a game that quietly lost the speed it was given the memory for.
  # What says which one ran is a measurement: the profile finds the routine where it really is.
  def test_a_routine_picked_by_number_runs_where_it_was_put
    rom = RubyGBA.build("PICKWHERE", code: "BPK5", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = var :n, 0
      which = var :which, 0
      b = self
      b.func(:busy, fast: true) { b.repeat(200) { n.add 1 } }
      game_loop { b.call [:busy], number: which }
    end
    busy = RubyGBA::Profiler.run(rom, frames: 30, picture: false).lines.find { |line| line.name == :busy }

    refute_nil busy, "the frame is spent in :busy, so the profile has to find it"
    assert_equal :quick_memory, busy.where
    assert_operator busy.share, :>, 50, "and that is where the frame went"
  end

  # A loop around it has to give up the two registers it would otherwise count in, exactly as a
  # plain call does — so this pins that the loop still counts right on the console.
  def test_a_loop_around_it_counts_right_on_the_console
    rom = RubyGBA.build("PICKLOOP", code: "BPK3", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      passes = var :passes, 0
      hits = var :hits, 0
      b = self
      b.func(:one) { hits.add 1 }
      b.func(:two) { hits.add 10 }
      game_loop do
        passes.set 0
        hits.set 0
        b.repeat(4) do |i|
          b.call %i[one two], number: i % 2
          passes.add 1
        end
        b.halt
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal 4, v.var(:passes), "the loop made its four passes"
    assert_equal 22, v.var(:hits), "...calling each routine twice"
  end

  # --- what it costs ---

  # THE WHOLE POINT: a list of a hundred and thirty-nine costs what a list of two does. A
  # dispatch that asked each name in turn would cost seventy times as much at that length.
  def test_the_cost_does_not_grow_with_the_length_of_the_list
    few = measure(dispatch_rom(2, code: "BPC1"))
    many = measure(dispatch_rom(MANY, code: "BPC2"))

    assert_in_delta few, many, few * 0.05,
                    "picking from #{MANY} routines cost #{many} instructions a frame against " \
                    "#{few} for picking from 2"
  end

  # ...and against what a game writes today: a test per routine, every one of them asked on
  # every dispatch.
  def test_it_beats_asking_each_routine_in_turn
    picked = measure(dispatch_rom(MANY, code: "BPC3"))
    asked = measure(chain_rom(MANY, code: "BPC4"))

    assert_operator asked, :>, picked * 5,
                    "asking each of #{MANY} routines in turn cost #{asked} instructions a frame " \
                    "against #{picked} for picking one"
  end

  # Two calls picking from the same list share one table, so the second costs the handful of
  # instructions that read it and none of the words — a table of 139 routines being 556 bytes
  # of the cartridge, per call, if each kept its own.
  def test_two_calls_picking_from_the_same_list_share_one_table
    one = GBA.new.lower(picking_program(1)).bytesize
    two = GBA.new.lower(picking_program(2)).bytesize

    assert_operator two - one, :<, MANY * 4,
                    "a second call picking from the same list grew the code by a whole table"
  end

  # --- what it refuses ---

  def test_a_single_routine_with_a_number_says_what_number_is_for
    err = assert_raises(ArgumentError) { program_with { call :only_one, number: 2 } }

    assert_match(/calls one routine/, err.message)
    assert_match(/give a list/, err.message)
  end

  def test_a_list_with_no_number_says_to_give_one
    err = assert_raises(ArgumentError) { program_with { call %i[a b] } }

    assert_match(/no number to pick one/, err.message)
  end

  def test_an_empty_list_is_refused
    err = assert_raises(ArgumentError) { program_with { call [], number: 0 } }

    assert_match(/empty list of routines/, err.message)
  end

  def test_something_that_is_not_a_routine_name_is_refused
    err = assert_raises(ArgumentError) { program_with { call [:a, "b"], number: 0 } }

    assert_match(/name of a routine/, err.message)
  end

  # A number holding a fraction would pick by its scaled-up bits, which is not the routine
  # anybody meant.
  def test_a_number_that_holds_a_fraction_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        speed = var :speed, 1.5
        call %i[a b], number: speed
      end
    end

    assert_match(/holds a fraction/, err.message)
    assert_match(/to_i/, err.message)
  end

  def test_a_written_number_past_the_end_of_the_list_is_refused
    err = assert_raises(ArgumentError) { program_with { call %i[a b], number: 5 } }

    assert_match(/numbered 0 to 1/, err.message)
  end

  # A number written into the program picks while the cartridge is built, so it is the plain
  # call it would have been written as — no table, no test, nothing to do as the game runs.
  def test_a_written_number_picks_while_building
    program = program_with do
      screen :bitmap
      n = var :n, 0
      b = self
      b.func(:first) { n.set 11 }
      b.func(:second) { n.set 22 }
      game_loop { b.call %i[first second], number: 1 }
    end
    kinds = program.walk.map(&:kind)

    refute_includes kinds, :call_one_of, "a number known while building needs no dispatch"
    assert_equal 22, Reference.new.run(program)[:n]
  end

  def test_a_routine_the_list_names_but_nobody_defined_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        which = var :which, 0
        b = self
        b.func(:defined) { b.halt }
        game_loop { b.call %i[defined missing], number: which }
      end
    end

    assert_match(/:missing is called but never defined/, err.message)
  end

  private

  # Three routines, each setting :n to its own number, and the number +which+ picking between
  # them. :n stays 0 when the number names none of them.
  def run_picking(which)
    program = program_with do
      screen :bitmap
      n = var :n, 0
      picked = var :picked, which
      b = self
      b.func(:first) { n.set 11 }
      b.func(:second) { n.set 22 }
      b.func(:third) { n.set 33 }
      game_loop { b.call %i[first second third], number: picked }
    end
    Reference.new.run(program)
  end

  # The middle rectangle is painted and the others are not: one call picks the middle one, and
  # two more are given numbers that name no routine — one past the end of the list and one
  # below its start — which paint nothing. On the console those two are held back by a single
  # test. Without it the number would be read that far along the table and the call would land
  # on whatever word was there.
  def drawing_program
    program_with do
      screen :bitmap
      clear_screen :black
      picked = var :picked, 1
      past_the_end = var :past_the_end, 7
      below_the_start = var :below_the_start, -1
      b = self
      b.func(:paint_left) { b.fill_rect 10, 10, 40, 40, :red }
      b.func(:paint_middle) { b.fill_rect 100, 10, 40, 40, :green }
      b.func(:paint_right) { b.fill_rect 190, 10, 40, 40, :blue }
      game_loop do
        b.call %i[paint_left paint_middle paint_right], number: picked
        b.call %i[paint_left paint_middle paint_right], number: past_the_end
        b.call %i[paint_left paint_middle paint_right], number: below_the_start
      end
    end
  end

  # +sites+ separate calls, all picking from one list of MANY routines.
  def picking_program(sites)
    names = (0...MANY).map { |i| :"op#{i}" }
    program_with do
      screen :bitmap
      n = var :n, 0
      which = var :which, 0
      names.each { |name| func(name) { n.add 1 } }
      b = self
      game_loop { sites.times { b.call names, number: which } }
    end
  end

  # A game that dispatches DISPATCHES times a frame, picking from +count+ routines by a number
  # read out of a table — so the number is worked out as it runs, as a script's would be.
  def dispatch_rom(count, code:, dispatches: DISPATCHES)
    names = (0...count).map { |i| :"op#{i}" }
    RubyGBA.build("PICKCOST", code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = var :n, 0
      steps = table :steps, (0...dispatches).map { |i| (i * 37) % count }
      names.each { |name| func(name) { n.add 1 } }
      b = self
      game_loop { b.repeat(dispatches) { |i| b.call names, number: steps[i] } }
    end
  end

  # The same game written the way it has to be written without this: one test per routine, and
  # every one of them asked on every dispatch.
  def chain_rom(count, code:)
    names = (0...count).map { |i| :"op#{i}" }
    RubyGBA.build("PICKCHAIN", code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = var :n, 0
      op = var :op, 0
      steps = table :steps, (0...DISPATCHES).map { |i| (i * 37) % count }
      names.each { |name| func(name) { n.add 1 } }
      b = self
      game_loop do
        b.repeat(DISPATCHES) do |i|
          op.set steps[i]
          names.each_with_index { |name, k| (op == k).then { b.call name } }
        end
      end
    end
  end

  # Instructions a frame, measured on a real run. Each of these games sleeps out the rest of
  # its frame, so what is counted is the work and not the waiting.
  def measure(rom)
    result = RubyGBA::Profiler.run(rom, frames: 30, picture: false)
    refute result.dropping_frames?,
           "this measurement only compares like with like while both games keep up (#{result.fps} fps)"
    result.samples_per_frame
  end
end
