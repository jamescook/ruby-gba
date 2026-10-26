# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# Every verb a game can write has an answer on every console — works or refused — decided and
# written down before a lowering does anything with it (Console::Answers). A verb added to the
# builder without one fails here, which is the moment to decide.
class TestAnswers < Minitest::Test
  include DslVerbs

  KITS = RubyGBA::Console.kits

  def test_every_verb_has_an_answer_on_every_console
    KITS.each do |kit|
      undecided = dsl_verbs.reject { |verb| kit.answers::ANSWERS.key?(verb) }
      assert_empty undecided, <<~MSG
        These verbs have no #{kit.title} answer in #{kit.answers.name}:
          #{undecided.join(', ')}
        Decide what each does on a #{kit.title} (works or refused) and say so in a sentence the
        build can print.
      MSG
    end
  end

  def test_every_answer_is_for_a_verb_a_game_can_write
    KITS.each do |kit|
      strays = kit.answers::ANSWERS.keys - dsl_verbs
      assert_empty strays, "#{kit.answers.name} answers for things that are not verbs: #{strays.join(', ')}"
    end
  end

  # Nothing is shown differently on any console: a verb works there, or is refused.
  def test_every_answer_works_or_is_refused_and_says_something
    KITS.each do |kit|
      kit.answers::ANSWERS.each do |verb, answer|
        assert_includes RubyGBA::Console::Answers::VERDICTS, answer.verdict, "#{kit.name} #{verb}"
        refute_empty answer.words.strip, "#{kit.name} #{verb} has a verdict and nothing to say about it"
      end
    end
  end

  # What is refused has to say why in words, not leave it to the table's words for a verb that works.
  def test_a_refusal_explains_itself
    KITS.each do |kit|
      plain = kit.answers.works.words
      vague = kit.answers::ANSWERS.reject { |_, answer| answer.works? }.select { |_, answer| answer.words == plain }
      assert_empty vague.keys, kit.name
    end
  end

  # The verbs were written for the Advance first, and it does every one of them.
  def test_the_advance_refuses_no_verb
    refused = RubyGBA::Console::AdvanceAnswers::ANSWERS.select { |_, answer| answer.refused? }
    assert_empty refused.keys
  end

  # The reference a reader looks each console's answers up in is those answers, written out.
  def test_each_consoles_reference_says_what_its_answers_say
    KITS.each do |kit|
      written = File.read(RubyGBA.root.join(kit.answers::PAGE))

      assert_equal kit.answers_page, written,
                   "#{kit.answers::PAGE} is out of date: run `ruby tools/console_answers.rb`"
    end
  end
end
