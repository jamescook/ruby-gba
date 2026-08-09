# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHICH SHAPE A `repeat` GETS, and that both shapes count right.
#
# A loop has to keep two numbers: how many passes it has made and how many it will make. Kept
# in memory, every pass loads both, compares, loads the counter again, adds one and stores it
# back — sixteen instructions, twelve of them reaching memory. Kept in registers it is a
# compare, a branch, an add and a branch.
#
# Registers are only safe when nothing in the body can land on them, so the build looks at the
# body and decides. The author writes `repeat` either way.
#
# The first half of this file is about which shape a body earns. The second half is the half
# that matters: a loop that got the fast shape has to produce exactly what the slow one would,
# and that is asserted against the reference interpreter and against the console.
class TestLoopForm < Minitest::Test
  LoopForm = RubyGBA::IR::Backends::GBA::LoopForm

  def program_with(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def shapes_of(&block)
    rom = RubyGBA.build("LOOPS", code: "BLPF", maker: "01", err: StringIO.new,
                                 out: StringIO.new, &block)
    [rom, rom.loop_shapes]
  end

  # --- which shape a body earns ---

  # Plain statements — arithmetic, list reads, a branch — leave the registers alone, and that
  # is what most loop bodies are.
  def test_a_plain_body_keeps_its_counter_in_a_register
    _, shapes = shapes_of do
      screen :bitmap
      xs = list :xs, capacity: 8
      8.times { |i| xs << i }
      total = var :total, 0
      b = self
      game_loop { b.repeat(8) { |i| (xs[i] > 2).then { total.add xs[i] } } }
    end

    assert_equal 1, shapes.length
    assert shapes.values.first.held, "nothing in that body can touch a register the loop needs"
  end

  # A CALL is the plainest reason it cannot: the routine may use any register it likes, and
  # this loop does not get to see inside it.
  def test_a_body_that_calls_goes_through_memory
    _, shapes = shapes_of do
      screen :bitmap
      moved = var :moved, 0
      b = self
      func(:bump) { moved.add 1 }
      game_loop { b.repeat(4) { b.call :bump } }
    end
    shape = shapes.values.first

    refute shape.held
    assert_equal "the body calls :bump", shape.blocked_by, "and it says which call"
  end

  # The other blockers, each for its own reason: a divide the game works out reaches the
  # console's own routine, and a drawn image clips each row in the high registers.
  def test_the_other_bodies_that_go_through_memory
    _, shapes = shapes_of do
      screen :bitmap
      image(:dot, "#" => :red, "." => :blue) { "#.\n.#" }
      n = var :n, 1
      d = var :d, 3
      out = var :out, 0
      x = var :bx, 8
      b = self
      game_loop do
        b.repeat(4) { out.set(n / d) }
        b.repeat(4) { b.blit :dot, x, 8 }
      end
    end
    reasons = shapes.values.map(&:blocked_by)

    assert_includes reasons, "a divide the game works out"
    assert_includes reasons, "the body draws an image"
  end

  # ...and blocking a drawn image is LOAD-BEARING, not caution. The row clipper works in the
  # very registers a held loop counts in, so a loop that kept its counter around one would
  # count in a number the clipper had just overwritten and run away entirely.
  def test_a_loop_around_a_drawn_image_counts_right_on_the_console
    rom = RubyGBA.build("LOOPBLIT", code: "BLBL", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      image(:dot, "#" => :red, "." => :blue) { "#.\n.#" }
      x = var :bx, 2
      passes = var :passes, 0
      b = self
      game_loop do
        passes.set 0
        b.repeat(7) do
          b.blit :dot, x, 60
          passes.add 1
        end
      end
    end

    assert_equal 7, read_var(rom, :passes)
  end

  # A BLOCKER HIDDEN DOWN A BRANCH still blocks. The body of a loop is a tree, and a call can
  # sit anywhere in it — under an `if`, or under its `else`, which an IR node keeps somewhere
  # different from the rest of its body. Missing one is not a wrong price, it is a wrong
  # answer: the call would land on the register the loop is counting in.
  def test_a_blocker_buried_in_a_branch_still_goes_through_memory
    _, shapes = shapes_of do
      screen :bitmap
      n = var :n, 0
      b = self
      func(:bump) { n.add 1 }
      game_loop do
        b.repeat(4) { |i| (i > 2).then { n.add 1 }.else { b.call :bump } }
      end
    end
    shape = shapes.values.first

    refute shape.held, "the call is in the else branch, and it still owns the registers"
    assert_equal "the body calls :bump", shape.blocked_by
  end

  # ...and the console proves what missing one costs. A loop down the else branch is the
  # sharpest case, because a loop is the one thing that certainly does take those registers:
  # the inner one would count in the outer one's counter, and the outer would never reach four.
  def test_a_loop_down_an_else_branch_counts_right_on_the_console
    rom = RubyGBA.build("LOOPELSE", code: "BLEL", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      total = var :total, 0
      b = self
      game_loop do
        total.set 0
        b.repeat(4) { |i| (i > 1).then { total.add 100 }.else { b.repeat(3) { total.add 1 } } }
      end
    end

    assert_equal 206, read_var(rom, :total), "i of 0 and 1 add three each, i of 2 and 3 add a hundred"
  end

  # The escape hatch is instructions the author wrote, which may use any register — so a loop
  # around one keeps its counter where nothing can reach it.
  def test_a_body_holding_raw_instructions_goes_through_memory
    node = RubyGBA::IR::Build.repeat(RubyGBA::IR::Build.int(4), :i, RubyGBA::IR::Build.raw(""))

    refute LoopForm.registers?(node)
  end

  # THE INVARIANT THE WHOLE THING RESTS ON: every statement kind NOT named as a blocker really
  # does leave the two registers alone. The blocker list is a claim about the rest of the
  # lowering, and a claim like that rots the moment someone emits a new statement that happens
  # to work in a high register — the loop around it would then count in a register somebody
  # else is using, and nothing would say so.
  #
  # So each kind is run inside a held loop that counts its own passes. A statement that landed
  # on the counter would leave a tally that is not seven. One ROM holds all of them, so the
  # sweep is a single boot however many kinds it grows to.
  SWEEP_PASSES = 7

  def test_no_other_statement_kind_lands_on_the_registers_a_held_loop_uses
    kinds = nil
    rom = RubyGBA.build("LOOPSWEEP", code: "BLSW", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      enable_sound
      define_sound :hit, frequency: 400, duty: :quarter, decay: :fast
      xs = list :xs, capacity: 8
      8.times { |i| xs << (i + 1) }
      curve = table :curve, (0...8).map { |i| i * 3 }
      n = var :n, 5
      other = var :other, 2
      b = self

      bodies = {
        set: ->(_i) { n.set 3 },
        add: ->(_i) { n.add 1 },
        sub: ->(_i) { n.sub 1 },
        copy: ->(_i) { b.copy :n, :other },
        negate: ->(_i) { n.flip },
        abs: ->(_i) { n.abs },
        clamp: ->(_i) { n.clamp 0, 9 },
        approach: ->(_i) { n.approach 4, 1 },
        branch: ->(_i) { (n > 2).then { n.set 1 }.else { n.set 8 } },
        multiply: ->(_i) { n.set(other * 3) },
        divide_by_a_fixed_number: ->(_i) { n.set(other / 3) },
        divide_by_a_power_of_two: ->(_i) { n.set(other / 4) },
        list_read: ->(i) { n.set xs[i] },
        list_write: ->(i) { xs[i] = 2 },
        table_read: ->(i) { n.set curve[i] },
        pixel: ->(_i) { b.pixel 4, 4, :red },
        fill_rect: ->(_i) { b.fill_rect 0, 0, 2, 2, :blue },
        draw_rect_at: ->(_i) { b.draw_rect_at other, 20, 4, 4, :green },
        draw_number: ->(_i) { b.draw_number :n, 0, 40, :white },
        random: ->(_i) { b.roll :n, 1..6 },
        beep: ->(_i) { b.beep :hit },
      }
      kinds = bodies.keys

      counts = kinds.to_h { |kind| [kind, b.var(:"count_#{kind}", 0)] }
      game_loop do
        bodies.each do |kind, body|
          count = counts[kind]
          count.set 0
          # The loop runs the statement and counts its own pass. A statement that landed on the
          # counter leaves this reading something other than SWEEP_PASSES.
          b.repeat(SWEEP_PASSES) do |i|
            body.call(i)
            count.add 1
          end
        end
      end
    end

    # Every loop in the sweep must have taken the fast shape, or it proves nothing about it.
    through_memory = rom.loop_shapes.reject { |_, shape| shape.held }
    assert_empty through_memory.transform_values(&:blocked_by),
                 "a body in this sweep is a blocker — either it belongs in the blocked list, or " \
                 "the sweep needs a different statement to stand for that kind"

    wrong = kinds.reject { |kind| read_var(rom, :"count_#{kind}") == SWEEP_PASSES }
    assert_empty wrong, "these statement kinds left the loop around them counting wrong"
  end

  # --- and both shapes count right, which is the half that matters ---

  # The same program either way: one loop the build can hold, one it cannot, both summing a
  # list. The reference interpreter says what the answers are; the lowering has to agree.
  def test_a_held_loop_counts_exactly_what_a_memory_loop_would
    program = program_with do
      screen :bitmap
      xs = list :xs, capacity: 8
      8.times { |i| xs << (i + 1) }
      held_total = var :held_total, 0
      memory_total = var :memory_total, 0
      b = self
      func(:add_one) { memory_total.add 1 }
      game_loop do
        b.repeat(8) { |i| held_total.add xs[i] } # plain body — in registers
        b.repeat(5) { b.call :add_one }          # calls out — through memory
        b.halt
      end
    end

    run = Reference.new.run(program)
    assert_equal 36, run[:held_total], "1 through 8 summed, by the loop that kept its counter"
    assert_equal 5, run[:memory_total]
  end

  # ...and the console agrees, which is the only place a clobbered register would show. Read
  # back out of memory rather than off the screen: the number IS the answer here.
  def test_the_console_agrees_about_both_shapes
    rom = RubyGBA.build("LOOPSUM", code: "BLSM", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      xs = list :xs, capacity: 8
      8.times { |i| xs << (i + 1) }
      held_total = var :held_total, 0
      memory_total = var :memory_total, 0
      b = self
      func(:add_one) { memory_total.add 1 }
      game_loop do
        held_total.set 0
        memory_total.set 0
        b.repeat(8) { |i| held_total.add xs[i] }
        b.repeat(5) { b.call :add_one }
      end
    end

    assert_equal 36, read_var(rom, :held_total)
    assert_equal 5, read_var(rom, :memory_total)
  end

  # A loop nested inside another still counts right, which is the case where the outer loop
  # cannot hold its counter and the inner one can.
  def test_a_nested_loop_counts_right_on_the_console
    rom = RubyGBA.build("LOOPNEST", code: "BLNS", maker: "01", err: StringIO.new, out: StringIO.new) do
      screen :bitmap
      total = var :total, 0
      b = self
      game_loop do
        total.set 0
        b.repeat(4) { b.repeat(5) { total.add 1 } }
      end
    end

    assert_equal 20, read_var(rom, :total)
  end

  SETTLE = 12

  def read_var(rom, name)
    address = rom.var_addresses.fetch(name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "loops.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(SETTLE)
      value = probe.read32(address)
      probe.close
      return value
    end
  end
end
