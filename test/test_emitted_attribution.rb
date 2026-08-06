# frozen_string_literal: true

require "test_helper"

require_relative "../tools/emitted_attribution"

# Which emitted bytes came from which part of the program (tools/emitted_attribution.rb).
# It is what turns "this change cost 18 instructions" into "18 instructions of clamp,
# in update_cpu, at three lines of the game".
#
# The claims worth pinning are that the bytes ADD UP, that they are charged to the
# statement that actually produced them, and that a containing statement is not
# charged for what it contains. Everything else the drill-down does is arithmetic on
# these numbers, and is tested without a backend in test_emitted_tool.rb.
class TestEmittedAttribution < Minitest::Test
  Attribution = EmittedAttribution

  def measure(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    Attribution.measure(GBA, b.program)
  end

  # Every byte is either charged to a statement or named as coming from outside one.
  #
  # Note what is NOT asserted here: that the columns sum to the total. They always
  # do, because the leftover is defined as the difference — so that equation holds
  # even when statements are charged twice and the leftover goes negative. The claim
  # with teeth is that no byte is charged more than once, which is the leftover being
  # a real, non-negative remainder.
  def test_no_byte_is_charged_twice
    breakdown = measure do
      screen :bitmap
      x = var :x, 0
      game_loop do
        wait_vblank
        clear_screen :black
        x.add 1
        x.clamp 0, 100
        fill_rect 10, 10, 20, 20, :red
      end
    end

    assert_operator breakdown.kinds.values.sum, :<=, breakdown.total,
                    "the statements were charged more bytes than the ROM has"
    assert_operator breakdown.unattributed, :>=, 0,
                    "a negative leftover means a byte was counted at more than one level of nesting"
    assert_operator breakdown.unattributed, :<, breakdown.total,
                    "nothing was attributed at all"
  end

  def test_bytes_are_charged_to_the_operation_that_produced_them
    breakdown = measure do
      screen :bitmap
      clear_screen :black
      fill_rect 10, 10, 20, 20, :red
      halt
    end

    assert_operator breakdown.kinds["fill_rect"].to_i, :>, 0
    assert_operator breakdown.kinds["clear_screen"].to_i, :>, 0
  end

  # A loop is charged for the loop's own bookkeeping — the jump back to the top —
  # not for everything inside it. Otherwise every byte would be counted again at
  # each level of nesting and no column would add up.
  def test_a_containing_statement_is_not_charged_for_what_it_contains
    breakdown = measure do
      screen :bitmap
      game_loop do
        wait_vblank
        20.times { |i| fill_rect i * 2, 10, 2, 2, :red }
      end
    end

    fills = breakdown.kinds["fill_rect"].to_i
    loops = breakdown.kinds["loop"].to_i

    assert_operator fills, :>, 0, "the fills are charged"
    assert_operator loops, :<, fills,
                    "the loop is charged for its own jump, not for the twenty fills inside it"
  end

  # A node knows the line of the game that asked for it, and the DSL block below is
  # in THIS file — so the attribution should name this file and the line the
  # fill_rect is written on.
  def test_bytes_are_charged_to_the_line_of_the_game_that_asked_for_them
    here = nil
    breakdown = measure do
      screen :bitmap
      here = __LINE__ + 1
      fill_rect 10, 10, 40, 40, :red
      halt
    end

    key = "#{File.basename(__FILE__)}:#{here}"
    assert_operator breakdown.lines[key].to_i, :>, 0,
                    "expected bytes charged to #{key}, got #{breakdown.lines.keys.first(5).inspect}"
  end

  # Grouping by line must not lose anything. Work the framework does on the game's
  # behalf mostly inherits the call site that asked for it — the frame sync written
  # into a game_loop is charged to the game_loop's line — but anything with no call
  # site at all is grouped under "(framework)" rather than dropped. Either way the
  # two columns account for exactly the same bytes.
  def test_grouping_by_line_accounts_for_the_same_bytes_as_grouping_by_operation
    breakdown = measure do
      screen :bitmap
      x = var :x, 0
      game_loop do
        wait_vblank
        clear_screen :black
        x.add 1
        fill_rect 0, 0, 8, 8, :red
      end
    end

    assert_equal breakdown.kinds.values.sum, breakdown.lines.values.sum,
                 "a line grouping that drops a statement would make the column silently short"
  end

  def test_funcs_are_measured_by_their_span_in_the_rom
    breakdown = measure do
      screen :bitmap
      func(:paint) { fill_rect 0, 0, 40, 40, :red }
      call :paint
      halt
    end

    assert_operator breakdown.funcs[:paint].to_i, :>, 0
  end

  # Recording must not change what is built — it is a subclass that watches, so the
  # ROM has to come out exactly as the plain backend makes it.
  def test_recording_the_breakdown_does_not_change_the_rom
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        wait_vblank
        clear_screen :black
        fill_rect 10, 10, 20, 20, :red
      end
    end
    b.emit_pending_functions
    program = b.program

    plain = GBA.new.lower(program)
    recorded = Attribution.recording(GBA).new.lower(program)

    assert_equal plain, recorded, "watching the build changed the build"
  end
end
