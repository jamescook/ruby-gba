# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# Every verb a game can write has a Game Boy Color answer — works, degrades or refused — decided
# and written down before the lowering does anything with it (Console::GBCFeatures). A verb added
# to the builder without one fails here, which is the moment to decide.
class TestGBCFeatures < Minitest::Test
  include DslVerbs

  ANSWERS = RubyGBA::Console::GBCFeatures::ANSWERS

  def test_every_verb_has_a_game_boy_color_answer
    undecided = dsl_verbs.reject { |verb| ANSWERS.key?(verb) }
    assert_empty undecided, <<~MSG
      These verbs have no Game Boy Color answer in lib/ruby_gba/console/gbc_features.rb:
        #{undecided.join(', ')}
      Decide what each does on a Game Boy Color (works, degrades or refused) and say so in a
      sentence the build can print.
    MSG
  end

  def test_every_answer_is_for_a_verb_a_game_can_write
    strays = ANSWERS.keys - dsl_verbs
    assert_empty strays, "Console::GBCFeatures answers for things that are not verbs: #{strays.join(', ')}"
  end

  def test_every_answer_is_one_of_the_three_and_says_something
    ANSWERS.each do |verb, answer|
      assert_includes RubyGBA::Console::GBCFeatures::VERDICTS, answer.verdict, verb.to_s
      refute_empty answer.words.strip, "#{verb} has a verdict and nothing to say about it"
    end
  end

  # What is refused or degrades has to say why in words, not leave it to the default.
  def test_a_refusal_or_a_lesser_version_explains_itself
    plain = RubyGBA::Console::GBCFeatures.works.words
    vague = ANSWERS.reject { |_, answer| answer.works? }.select { |_, answer| answer.words == plain }
    assert_empty vague.keys
  end

  # The reference a reader looks the answers up in is these answers, written out, with what the
  # Color's build does not make yet.
  def test_the_reference_says_what_the_answers_and_the_build_say
    written = File.read(RubyGBA.root.join(".claude/dsl/game-boy-color.md"))
    said = RubyGBA::Console::GBCFeatures.reference(not_yet: RubyGBA::IR::Backends::GBC::StatementLowering::NOT_LOWERED_YET)

    assert_equal said, written, "the Game Boy Color reference is out of date: run `ruby tools/gbc_answers.rb`"
  end
end
