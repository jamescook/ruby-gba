# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The timed-trigger verbs: every(n) { } runs a block every n frames, after(n) { }
# runs one once after n frames. Both are core control-flow verbs — siblings of
# repeat and game_loop — built on a hidden frame counter the library manages for
# the user (like repeat's hidden index), so there's no counter to declare, reset,
# or forget.
#
# These assert BEHAVIOR on the reference backend: build a small game loop, run it
# a fixed number of frames, and check how often (and when) the block fired. A
# gemba test confirms the schedule holds on real hardware.
class TestTimers < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  Build = RubyGBA::IR::Build
  Color = RubyGBA::Color

  def interpret(**opts, &block)
    Reference.new.run(tree(&block), **opts)
  end

  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # A loop that runs `frames` frames, counting them in :frame, then halts — so a
  # timer's behavior over a known window is observable. The block is spliced into
  # the loop body after the frame counter ticks.
  def run_for(frames, &body)
    interpret(frames: frames) do
      var :frame, 0
      var :fires, 0
      var :last_fire, 0
      game_loop do
        wait_vblank
        add :frame, 1
        instance_exec(&body)
        if_ge :frame, frames do
          halt
        end
      end
    end
  end

  # ---- after: once, on the nth frame ----

  def test_after_fires_exactly_once
    i = run_for(20) do
      after(5) { add :fires, 1 }
    end
    assert_equal 1, i[:fires], "after(5) should fire exactly once across 20 frames"
  end

  def test_after_fires_on_the_nth_frame
    i = run_for(20) do
      after(5) do
        add :fires, 1
        copy :last_fire, :frame # capture which frame it fired on
      end
    end
    assert_equal 5, i[:last_fire], "after(5) should fire on the 5th frame"
  end

  # If it fired inside the loop with the counter re-zeroed each pass, it would
  # never reach n. Reaching n exactly once proves the counter is hoisted to boot.
  def test_after_does_not_fire_before_its_time
    i = run_for(3) do
      after(5) { add :fires, 1 }
    end
    assert_equal 0, i[:fires], "after(5) shouldn't fire within the first 3 frames"
  end

  # ---- every: on a regular schedule ----

  def test_every_fires_on_each_multiple
    i = run_for(12) do
      every(3) { add :fires, 1 }
    end
    assert_equal 4, i[:fires], "every(3) over 12 frames should fire on 3,6,9,12"
  end

  def test_every_one_fires_each_frame
    i = run_for(7) do
      every(1) { add :fires, 1 }
    end
    assert_equal 7, i[:fires], "every(1) should fire every frame"
  end

  # ---- seconds: think in time, the framework converts to frames ----

  def test_after_seconds_converts_at_the_frame_rate
    # 1 second is 60 frames, so it should fire on the 60th.
    i = run_for(80) do
      after(1, :seconds) do
        add :fires, 1
        copy :last_fire, :frame
      end
    end
    assert_equal 1, i[:fires]
    assert_equal 60, i[:last_fire], "after(1, :seconds) should fire on frame 60"
  end

  def test_every_seconds_can_be_fractional
    # Half a second is 30 frames -> fires on 30 and 60.
    i = run_for(60) do
      every(0.5, :seconds) { add :fires, 1 }
    end
    assert_equal 2, i[:fires], "every(0.5, :seconds) should fire on frames 30 and 60"
  end

  def test_timer_rejects_an_unknown_unit
    err = assert_raises(ArgumentError) { tree { after(3, :hours) { nil } } }
    assert_match(/unit/, err.message)
  end

  # ---- independence: separate timers keep separate counters ----

  def test_two_timers_do_not_interfere
    i = interpret do
      var :frame, 0
      var :a, 0
      var :b, 0
      game_loop do
        wait_vblank
        add :frame, 1
        every(2) { add :a, 1 } # 2,4,6,8,10 -> 5
        every(5) { add :b, 1 } # 5,10 -> 2
        if_ge :frame, 10 do
          halt
        end
      end
    end
    assert_equal 5, i[:a]
    assert_equal 2, i[:b]
  end

  # ---- boot init: the hidden counter starts from zero at power-on ----
  #
  # Console RAM isn't reliably zero at boot, so the counter must be cleared once
  # at the very start — outside the loop, or it would reset every frame and the
  # timer would never advance. The interpreter defaults vars to 0, so this pins
  # the hardware-safety contract structurally: the clear is hoisted to the front.

  def test_the_hidden_counter_is_cleared_at_boot
    program = tree do
      game_loop do
        wait_vblank
        after(5) { halt }
      end
    end
    # The loop is the last top-level statement; a zero-clear must come before it.
    loop_index = program.children.index { |n| n.kind == :loop }
    before_loop = program.children[0...loop_index]
    assert before_loop.any? { |n| n.kind == :set && n[:value].kind == :int && n[:value][:value].zero? },
           "a timer's counter should be zero-initialized before the game loop"
  end

  # ---- lowering: a timer node is a plain frame counter + compare ----
  #
  # The GBA backend lowers every/after to a hidden frame counter and a compare.
  # Pin that lowering by building the node form and the equivalent explicit
  # counter+compare form and asserting identical generated code (two fresh backends
  # label gensyms the same way, so equal bytes means an equal instruction stream).
  def test_every_lowers_identically_to_an_explicit_counter_compare
    node_form = Build.program(
      Build.screen(:bitmap), Build.set(:c, 0),
      Build.loop_(Build.wait_vblank, Build.every(:c, 3, Build.set(:hit, 1)), Build.halt),
    )
    explicit_form = Build.program(
      Build.screen(:bitmap), Build.set(:c, 0),
      Build.loop_(Build.wait_vblank,
                  Build.add(:c, 1), # counter += 1
                  Build.if_(Build.binop(:>=, Build.var_ref(:c), Build.int(3)),
                            Build.set(:c, 0), Build.set(:hit, 1)), # on reach: reset, then body
                  Build.halt),
    )
    assert_equal GBA.new.lower(explicit_form), GBA.new.lower(node_form)
  end

  def test_after_lowers_identically_to_an_explicit_counter_compare
    node_form = Build.program(
      Build.screen(:bitmap), Build.set(:c, 0),
      Build.loop_(Build.wait_vblank, Build.after(:c, 5, Build.set(:hit, 1)), Build.halt),
    )
    explicit_form = Build.program(
      Build.screen(:bitmap), Build.set(:c, 0),
      Build.loop_(Build.wait_vblank,
                  Build.if_(Build.binop(:<, Build.var_ref(:c), Build.int(5)),
                            Build.add(:c, 1), # count up only until the target...
                            Build.if_(Build.binop(:==, Build.var_ref(:c), Build.int(5)),
                                      Build.set(:hit, 1))), # ...and fire on the frame it lands on
                  Build.halt),
    )
    assert_equal GBA.new.lower(explicit_form), GBA.new.lower(node_form)
  end

  # ---- guardrails ----

  def test_every_rejects_a_non_positive_interval
    err = assert_raises(ArgumentError) { tree { every(0) { nil } } }
    assert_match(/every/, err.message)
  end

  def test_after_rejects_a_non_positive_interval
    err = assert_raises(ArgumentError) { tree { after(-3) { nil } } }
    assert_match(/after/, err.message)
  end

  def test_every_rejects_a_non_integer_interval
    assert_raises(ArgumentError) { tree { every(2.5) { nil } } }
  end

  def test_every_needs_a_block
    err = assert_raises(ArgumentError) { tree { every(3) } }
    assert_match(/block/, err.message)
  end

  # ---- hardware: the schedule holds on the console ----
  #
  # Blink a marker on and off — the real title-screen use. after(2) turns it on;
  # once on, every(4) flips it. Running a fixed number of frames lands on a known
  # on/off phase the interpreter and the console must agree on.

  def blink_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      shown = var :shown, 0
      f = var :f, 0
      game_loop do
        wait_vblank
        clear_screen :white
        after(2) { shown.set 1 } # turn the marker on after 2 frames
        (shown == 1).then { dma_fill_rect 100, 80, 8, 8, :red }
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_after_drives_a_marker_on_both_backends
    program = blink_program(frames: 4)
    i = Reference.new.run(program)
    assert_equal Color.resolve(:red), i.screen.pixel(103, 83), "interpreter: marker on after 2 frames"

    rom = RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(program),
                                title: "TIMERS", code: "BTMR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.red?(103, 83), "console: the after(2) marker is drawn"
  end
end
