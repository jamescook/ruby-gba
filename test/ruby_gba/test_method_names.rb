# frozen_string_literal: true

require "test_helper"

# A method's name has to tell a reader what calling it does, without opening the body. That is a
# judgement no test can make, so this checks only the half of it a pattern can see: the shapes that
# kept turning up in names that told the reader nothing — articles and prose, a vague verb with no
# object, a two-letter abbreviation, a whole sentence. See "Naming methods" in .claude/CLAUDE.md.
class TestMethodNames < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  # `the_`, `an_`, and a lone `a_` read as prose. "a frame" meaning "per frame" is a rate, not an
  # article, and the console's sound channel A is a name — those two are let through.
  ARTICLE = /(?:\A|_)(?:the|an)(?:_|\z)|(?:\A|_)a_(?!frame\z|config\z)/

  # A verb that says something happens without saying what.
  VAGUE_VERB = /\A(?:handle|process|do|deal_with|sort_out|settle|take_care_of)_/

  # Seven words is a sentence, not a name. Six can still be a precise one — "emit divide by
  # power of two" says exactly what comes out — and the prose six-word names use articles.
  MOST_WORDS = 6

  # Two letters is an abbreviation unless it is one of these, which every reader already knows.
  # `bx` is the ARM instruction of that name, and `ok?` is plain English.
  SHORT_NAMES = %w[x y w h id at of to io op ok bx].freeze

  def defined_methods
    Dir.glob("#{LIB}/**/*.rb").flat_map do |path|
      File.foreach(path).with_index(1).filter_map do |line, number|
        name = line[/^\s*def (?:self\.)?([a-z_][a-zA-Z0-9_]*[?!=]?)/, 1]
        [name, "#{path.delete_prefix("#{LIB}/")}:#{number}"] if name
      end
    end
  end

  def offenders(&rule)
    defined_methods.select { |name, _| rule.call(name.delete_suffix("?").delete_suffix("!").delete_suffix("=")) }
                   .map { |name, where| "#{where}  #{name}" }
  end

  def assert_none(found, why)
    assert_empty found, "#{why}\n#{found.join("\n")}"
  end

  def test_no_method_name_reads_as_prose
    assert_none offenders { |name| name.match?(ARTICLE) },
                "These names use an article (the_, a_, an_). Name what the method does instead:"
  end

  def test_no_method_name_starts_with_a_verb_that_says_nothing
    assert_none offenders { |name| name.match?(VAGUE_VERB) },
                "These names start with a verb that hides what happens. Say what is raised, " \
                "emitted, allocated or returned:"
  end

  def test_no_method_name_is_a_sentence
    assert_none offenders { |name| name.delete_prefix("_").split("_").size > MOST_WORDS },
                "These names are #{MOST_WORDS + 1} words or more. Name the thing, do not narrate it:"
  end

  def test_no_method_name_is_a_two_letter_abbreviation
    assert_none offenders { |name| name.length <= 2 && !SHORT_NAMES.include?(name) },
                "These names are abbreviations. Spell out what they hold or do:"
  end
end
