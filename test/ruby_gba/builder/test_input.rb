# frozen_string_literal: true

require "test_helper"

class TestInput < Minitest::Test
  include RubyGBA::Console::Hardware

  def build(validate: false, &block)
    RubyGBA.build("INPTEST", validate: validate, &block)
  end

  def instructions(rom)
    start = RubyGBA::Cartridge::ROM::ENTRY_OFFSET
    result = []
    offset = start
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0
      result << word
      offset += 4
    end
    result
  end

  # ========================================================================
  # if_held
  # ========================================================================

  def test_if_held_builds_without_error
    rom = build do
      screen :bitmap
      set! :player_y, 80
      game_loop do
        if_held :up do
          sub_var! :player_y, 2
        end
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_if_held_unknown_button_raises
    assert_raises(ArgumentError) do
      build do
        if_held :turbo do
          halt
        end
      end
    end
  end

  def test_if_held_all_buttons
    # Every button should be accepted without error
    %i[a b select start right left up down r l].each do |btn|
      rom = build do
        if_held btn do
          set! :x, 1
        end
        halt
      end
      assert_operator rom.size, :>, 0, "button #{btn} should work"
    end
  end

  def test_if_held_emits_conditional_branch
    rom = build do
      if_held :up do
        set! :y, 1
      end
      halt
    end

    insts = instructions(rom)
    # Should contain a BNE (cond=0x1) that skips over the block
    has_bne = insts.any? { |i| branch?(i) && cond(i) == 0x1 }
    assert has_bne, "expected BNE (skip block if button not pressed)"
  end

  def test_if_held_branch_skips_correct_distance
    rom = build do
      if_held :a do
        set! :x, 42
      end
      halt
    end

    insts = instructions(rom)
    # Find the BNE instruction
    bne_idx = insts.index { |i| branch?(i) && cond(i) == 0x1 }
    refute_nil bne_idx, "should have a BNE"

    # Decode the branch target
    offset = signed_branch_offset(insts[bne_idx])
    target_idx = bne_idx + 2 + offset  # PC is 2 ahead

    # The halt (loop_forever) should be at or after target_idx
    halt_idx = insts.index(0xEAFFFFFE)
    assert_operator target_idx, :<=, halt_idx + 1,
      "BNE should skip to the instruction after the set block"
  end

  # ========================================================================
  # if_pressed (edge detection)
  # ========================================================================

  def test_if_pressed_builds_without_error
    rom = build do
      screen :bitmap
      game_loop do
        if_pressed :start do
          set! :state, 1
        end
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_if_pressed_emits_beq
    rom = build do
      if_pressed :start do
        set! :state, 1
      end
      halt
    end

    insts = instructions(rom)
    # if_pressed uses BEQ to skip (Z=1 means not newly pressed)
    has_beq = insts.any? { |i| branch?(i) && cond(i) == 0x0 }
    assert has_beq, "expected BEQ (skip block if button not newly pressed)"
  end

  # A BUTTON HELD WHILE THE POWER COMES ON IS ONE PRESS. Nothing was down before the game
  # started, so the first frame that finds it down is its press edge — the same one press a
  # button held for any other stretch is, however long it stays down. The console starts with
  # nothing down; the interpreter used to count the button as already down before the first
  # frame, and so never saw the press at all. A press asked about before the first frame
  # (setting up, above the loop) is never one: no frame has read the buttons yet.
  private def counting_presses
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      presses = var :presses, 0
      before_the_loop = var :before_the_loop, 0
      pressed(:start).then { before_the_loop.set! 1 }
      game_loop { pressed(:start).then { presses.add! 1 } }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_button_held_from_power_on_is_one_press_on_both_backends
    program = counting_presses
    oracle = RubyGBA::IR::Backends::Reference.new.hold(:start).run(program, frames: 6)
    assert_equal [1, 0], [oracle[:presses], oracle[:before_the_loop]]

    rom = assemble_rom(program, name: "HELDPOWER")
    v = assert_emulator_loads_rom(rom, frames: 7, keys: KEY_START, vars: rom.var_addresses)
    assert_equal [1, 0], [v.var(:presses), v.var(:before_the_loop)]
  end

  # A PRESS IS NEVER LOST TO A SLOW GAME. A game whose pass takes two frames goes round the
  # loop thirty times a second, and a tap that goes down and comes up again inside one pass
  # used to be missed: both of the pass's readings found the button up. The buttons are
  # read on every frame the screen shows, so a tap one frame long is one press whichever
  # frame it lands on — and a press held for several frames is still one.
  #
  # Six whole-screen clears make a pass take two frames on the console, and the interpreter
  # is told so. Tapping on two neighbouring frames puts
  # one of the taps inside a pass, whatever frame the passes happen to start on.
  private def slow_game_counting_presses
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      presses = var :presses, 0
      game_loop do
        repeat(6) { clear_screen :blue }
        pressed(:a).then { presses.add! 1 }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  TAPPED = { "one frame on frame 20" => [20], "one frame on frame 21" => [21],
             "six frames from frame 20" => (20..25).to_a }.freeze

  def test_a_slow_game_counts_every_tap_once_in_the_interpreter
    TAPPED.each do |what, down|
      oracle = RubyGBA::IR::Backends::Reference.new
                                               .frames_each_pass { 2 }
                                               .input_each_frame { |frame| down.include?(frame) ? [:a] : [] }
                                               .run(slow_game_counting_presses, frames: 20)

      assert_equal 1, oracle[:presses], "A held #{what}"
    end
  end

  def test_a_slow_game_counts_every_tap_once_on_the_console
    rom = assemble_rom(slow_game_counting_presses, name: "SLOWTAPS")
    TAPPED.each do |what, down|
      keys = ->(frame) { down.include?(frame) ? KEY_A : 0 }
      v = assert_emulator_loads_rom(rom, frames: 40, keys: keys, vars: rom.var_addresses)

      assert_equal 1, v.var(:presses), "A held #{what}"
    end
  end

  # A TAP WHILE THE GAME SETS UP IS NOT A PRESS. The screen is off until the game loop's first
  # frame, so nothing a player does then has anything to answer — and the console reads no
  # buttons for the game before it either, the way a retail game reads none before its main
  # loop. A button still down when the loop starts is one press, like one held from power-on.
  #
  # Console only: the interpreter's setting up takes no frames, so a tap cannot land in it.
  # Twenty whole-screen clears above the loop are several frames of setting up.
  private def slow_setup_counting_presses
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      presses = var :presses, 0
      repeat(20) { clear_screen :blue }
      game_loop { pressed(:a).then { presses.add! 1 } }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_tap_while_the_game_sets_up_is_not_a_press
    rom = assemble_rom(slow_setup_counting_presses, name: "SETUPTAP")
    tap = ->(frame) { frame == 1 ? KEY_A : 0 }
    still_down = ->(frame) { frame >= 1 ? KEY_A : 0 }

    assert_equal 0, assert_emulator_loads_rom(rom, frames: 20, keys: tap, vars: rom.var_addresses).var(:presses),
                 "a tap made and let go while the game set up"
    assert_equal 1, assert_emulator_loads_rom(rom, frames: 20, keys: still_down, vars: rom.var_addresses).var(:presses),
                 "a button pressed while the game set up and still down when the loop starts"
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_input_rom_runs_in_mgba
    rom = build do
      screen :bitmap
      set! :player_y, 80
      game_loop do
        if_held :up do
          sub_var! :player_y, 2
        end
        if_held :down do
          add_var! :player_y, 2
        end
        if_pressed :start do
          set! :player_y, 80
        end
      end
    end

    assert_emulator_loads_rom(rom, frames: 10)
  end

  private

  def branch?(inst)
    (inst & 0x0E000000) == 0x0A000000
  end

  def cond(inst)
    (inst >> 28) & 0xF
  end

  def signed_branch_offset(inst)
    offset = inst & 0x00FFFFFF
    (offset & 0x800000) != 0 ? offset - 0x1000000 : offset
  end
end
