# frozen_string_literal: true

require "test_helper"

# The games these tests play, shared with the Advance cartridge's own tests of the buttons
# (test/lowering/gba/vblank/builder/test_input_cartridge.rb) and the interpreter's
# (test/interpreter/vblank/builder/test_input_interpreter.rb).
module InputGames
  include SharedConstants

  private def build(validate: false, &block)
    VBlank.build("INPTEST", console: :gba, validate: validate, out: nil, err: nil, &block)
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
    builder.finalize_program
    builder.program
  end

  # ANY BUTTON AT ALL — how a game gets out of an attract screen. `held(:any)` holds while
  # something is down; `pressed(:any)` is true on a frame some button went down, so pressing A
  # while LEFT is still held is a press, and a button held on and on is one press however long.
  private def counting_any_button
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      held_frames = var :held_frames, 0
      presses = var :presses, 0
      game_loop do
        held(:any).then { held_frames.add! 1 }
        pressed(:any).then { presses.add! 1 }
      end
    end
    builder.finalize_program
    builder.program
  end

  # LEFT for three frames, then A as well for two, then nothing, then B for one: six frames
  # with something down, and three presses — LEFT, A on top of LEFT, and B.
  # Made shareable here, since only a test class's own constants are frozen for its Ractor.
  ANY_BUTTON_FRAMES = Ractor.make_shareable({ 3 => [:left], 4 => [:left], 5 => [:left], 6 => %i[left a],
                                              7 => %i[left a], 9 => [:b] })

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
    builder.finalize_program
    builder.program
  end

  TAPPED = Ractor.make_shareable({ "one frame on frame 20" => [20], "one frame on frame 21" => [21],
                                   "six frames from frame 20" => (20..25).to_a })
end

# The buttons, as every run plays them. What the Advance's cartridge is built of and does with
# them is in test/lowering/gba/vblank/builder/test_input_cartridge.rb, and a slow game told to
# the interpreter in test/interpreter/vblank/builder/test_input_interpreter.rb.
class TestInput < Minitest::Test
  include InputGames

  def test_if_held_unknown_button_raises
    assert_raises(ArgumentError) do
      build do
        if_held :turbo do
          halt
        end
      end
    end
  end

  def test_a_button_held_from_power_on_is_one_press_on_both_backends
    program = counting_presses
    played = game_player.hold(:start).run(program, frames: 6)
    assert_equal [1, 0], [played[:presses], played[:before_the_loop]]
  end

  def test_any_button_is_held_and_pressed_on_both_backends
    program = counting_any_button
    played = game_player.input_each_frame { |frame| ANY_BUTTON_FRAMES.fetch(frame, []) }
                        .run(program, frames: 14)
    assert_equal [6, 3], [played[:held_frames], played[:presses]]
  end

  # `:any` is not a button, so the list a typo is answered with does not offer it, and a test
  # cannot hold it — holding "any button" says nothing about which.
  def test_unknown_button_message_does_not_offer_any
    message = assert_raises(ArgumentError) { build { if_held(:turbo) { halt } } }.message

    refute_match(/:any/, message)
    assert_raises(VBlank::IR::Backends::Reference::ProgramError) do
      VBlank::IR::Backends::Reference.new.hold(:any).run(counting_any_button, frames: 2)
    end
  end
end
