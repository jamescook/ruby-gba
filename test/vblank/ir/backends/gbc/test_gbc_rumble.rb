# frozen_string_literal: true

require "test_helper"

# A COLOR CARTRIDGE THAT RUMBLES (`rumble`, Runtime::Rumble): it says in its header that it carries
# a motor, and the game runs the motor a frame at a time by the pattern it said, as Pokémon
# Pinball shakes the player's hands when the ball hits a bumper. The emulator reports the motor as
# the cartridge sets it.
class TestGBCRumble < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # A game that rumbles in "##..#.#." for ten frames on the pass that sees A pressed, keeping
  # +saving+ a save variable it writes as it rumbles.
  private def bumper(saving: false, with_clock: false)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      hits = saving ? save_var(:hits, 0) : var(:hits, 0)
      clock.present?.then { hits.add! 0 } if with_clock
      game_loop do
        pressed(:a).then do
          rumble frames: 10, pattern: "##..#.#."
          hits.add! 1
        end
      end
    end
    b.finalize_program
    b.program
  end

  PRESS = 20

  # The motor on each frame from power-on, as "#" and ".", A pressed on frame PRESS.
  private def felt(program, frames: PRESS + 16)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "BUMPER")
    a = VBlank::Console::Hardware::KEY_A
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0, keys: ->(played) { played + 1 == PRESS ? a : 0 })
    Array.new(frames) { v.step.motor_on? ? "#" : "." }.join
  end

  def test_the_motor_runs_the_pattern_for_the_frames_said
    # The press is held on frame PRESS, the pass that sees it says the rumble, and the motor runs
    # from the frame after: ten frames of the pattern, round again, then still.
    assert_equal "#{'.' * PRESS}##..#.#.##......", felt(bumper)
  end

  def test_the_motor_runs_beside_save_memory
    assert_equal felt(bumper), felt(bumper(saving: true))
  end

  def test_the_cartridge_says_it_carries_a_motor
    at = VBlank::Console::GBCHardware::CARTRIDGE_TYPE_AT
    plain = GBC.new.build(bumper, title: "BUMPER").bytes.getbyte(at)
    saving = GBC.new.build(bumper(saving: true), title: "BUMPER").bytes.getbyte(at)

    assert_equal [VBlank::Cartridge::GBCROM::MBC5_RUMBLE, VBlank::Cartridge::GBCROM::MBC5_RUMBLE_RAM_BATTERY], [plain, saving]
  end

  # The checked run compares the motor on every pass, as well as the save memory the game writes.
  def test_a_rumbling_game_plays_as_the_interpreter_plays_it
    game_player.input_each_frame { |frame| frame == 4 ? [:a] : [] }.run(bumper(saving: true), frames: 20)
  end

  def test_a_game_with_a_clock_cannot_rumble
    error = assert_raises(GBC::LoweringError) { GBC.new.build(bumper(with_clock: true), title: "BUMPER") }

    assert_match(/clock/, error.message)
    assert_match(/rumble/, error.message)
  end
end
