# frozen_string_literal: true

require "test_helper"

# A PART A CONSOLE'S BUILD DOES NOT MAKE YET is a skip naming the part, on every console whose
# cartridge a run plays (Testing::CartridgeCheckedPlayer), so a run's count of skips by reason says
# what is left to make: the Color's the same as the Super Nintendo's. A refusal of anything else is
# a fault, and fails.
class TestCartridgeCheckedPlayer < Minitest::Test
  Testing = VBlank::Testing
  Backends = VBlank::IR::Backends
  BACKENDS = { gbc: Backends::GBC, snes: Backends::SNES }.freeze

  # The player of +console+'s run, over a checked run that refuses every program with +error+.
  private def player_refusing(console, error)
    refusing = Class.new { define_method(:run) { |_program, max_steps: nil, frames: nil| raise error } }
    Class.new(refusing) { include Testing::CartridgeCheckedPlayer }.tap do |player|
      player.extend(Testing::CartridgeCheckedPlayer::OfConsole)
      player.define_singleton_method(:console) { console }
    end
  end

  private def program = VBlank::IR::Build.program(VBlank::IR::Build.halt)

  def test_a_part_not_made_yet_is_a_skip_naming_it_on_every_cartridge_run
    BACKENDS.each do |console, backend|
      error = backend::Lowering::NotMadeYet.new("not made", part: "the picture")
      skip = assert_raises(Minitest::Skip) { player_refusing(console, error).new.run(program) }

      assert Testing::MissingFeature === skip, "#{console}: a missing feature, which the run counts"
      title = VBlank::Console.described(console).title
      assert_equal "#{title} build does not make yet: the picture", skip.message
    end
  end

  def test_any_other_refusal_fails
    BACKENDS.each do |console, backend|
      error = backend::LoweringError.new("broken")

      assert_raises(backend::LoweringError) { player_refusing(console, error).new.run(program) }
    end
  end

  # The shared plan raises the lowering's own error for it, naming the part and the console.
  def test_the_plan_names_the_part_a_kind_is_in
    BACKENDS.each do |console, backend|
      described = VBlank::Console.described(console)
      plan = Backends::LoweringPlan.new(VBlank::IR::Build.program(VBlank::IR::Build.halt), console: described,
                                                                                            error: backend::LoweringError)
      error = assert_raises(backend::Lowering::NotMadeYet) { plan.refuse_kinds_not_made_yet!({ "the ending" => %i[halt] }, backend::Lowering::NotMadeYet) }

      assert_equal "the ending", error.part
      assert_match(/The #{described.title} build does not make that yet/, error.message)
    end
  end
end
