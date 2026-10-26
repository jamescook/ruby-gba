# frozen_string_literal: true

require "test_helper"

# `uses`: a game brings in effects of its own — a module of verbs written in the game's own verbs —
# for its build alone. Nothing is added to every other game the process builds, so two games can
# each have a verb of the same name, and a game built in a Ractor can use one.
class TestUses < Minitest::Test
  # A pack of one verb that paints the screen a colour, and a private helper it calls.
  module PaintsRed
    def paint_it = clear_screen(paint_colour)

    private

    def paint_colour = :red
  end

  # ...and another game's pack with a verb of the same name.
  module PaintsBlue
    def paint_it = clear_screen(:blue)
  end

  # A pack whose name is one ruby-gba already has.
  module TakesFillRect
    def fill_rect(*) = nil
  end

  # A pack that takes the name from a module it includes.
  module IncludesFillRect
    include TakesFillRect
  end

  # Two packs that share a helper module: the same helper twice is not two names.
  module SharedPaint
    def paint_colour_of(name) = name
  end

  # The first pack that shares it.
  module PaintsGreen
    include SharedPaint
    def paint_green = clear_screen(paint_colour_of(:green))
  end

  # The second pack that shares it.
  module PaintsWhite
    include SharedPaint
    def paint_white = clear_screen(paint_colour_of(:white))
  end

  # A pack carrying a check of its own, which says something about every program it sees.
  module Checked
    # The check, said once for the whole build.
    class SaysHello
      NAME = :says_hello
      PLAIN_NAME = "a pack's own check"

      def detect(program)
        [RubyGBA::IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: "This game uses the Checked pack.",
                                              node: program)]
      end
    end

    CHECKS = Ractor.make_shareable([SaysHello.new])
    def self.checks = CHECKS

    def say_nothing = nil
  end

  private def game(&body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      instance_exec(&body)
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  private def corner(prog) = game_player.run(prog, frames: 2).screen.pixel(0, 0)

  def test_a_game_uses_a_pack_of_its_own
    assert_equal Color.resolve(:red), corner(game { uses PaintsRed; paint_it })
  end

  # Two games in one process, each with a verb called `paint_it`, each get their own.
  def test_two_games_can_each_have_a_verb_of_the_same_name
    assert_equal Color.resolve(:red), corner(game { uses PaintsRed; paint_it })
    assert_equal Color.resolve(:blue), corner(game { uses PaintsBlue; paint_it })
  end

  def test_a_pack_is_not_every_games
    game { uses PaintsRed; paint_it }

    assert_raises(NameError) { game { paint_it } }
  end

  def test_a_pack_cannot_take_a_name_ruby_gba_has
    [TakesFillRect, IncludesFillRect].each do |pack|
      error = assert_raises(RubyGBA::Effects::DuplicateVerb) { game { uses pack } }

      assert_match(/`fill_rect`/, error.message, pack.name)
      assert_match(/ruby-gba/, error.message, pack.name)
    end
  end

  def test_two_packs_can_share_a_module
    assert_equal Color.resolve(:white), corner(game { uses PaintsGreen, PaintsWhite; paint_green; paint_white })
  end

  def test_two_packs_in_one_game_cannot_take_one_name
    error = assert_raises(RubyGBA::Effects::DuplicateVerb) { game { uses PaintsRed, PaintsBlue } }

    assert_match(/`paint_it`/, error.message)
    assert_match(/PaintsRed/, error.message)
  end

  def test_using_a_pack_twice_does_nothing_the_second_time
    assert_equal Color.resolve(:red), corner(game { uses PaintsRed; uses PaintsRed; paint_it })
  end

  def test_uses_takes_modules
    error = assert_raises(ArgumentError) { game { uses Object } }

    assert_match(/module/, error.message)
  end

  # A pack's checks report on the build that uses it, and on no other.
  def test_a_packs_checks_join_the_build_that_uses_it
    said = StringIO.new
    RubyGBA.build("USESCHECK", console: :gba, out: said, err: said) do
      uses Checked
      game_loop {}
    end
    quiet = StringIO.new
    RubyGBA.build("NOCHECK", console: :gba, out: quiet, err: quiet) { game_loop {} }

    assert_match(/uses the Checked pack/, said.string)
    refute_match(/uses the Checked pack/, quiet.string)
  end
end
