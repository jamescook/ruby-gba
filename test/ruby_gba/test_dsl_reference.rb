# frozen_string_literal: true

require "test_helper"
require "dsl_verbs"

# Keeps the DSL reference honest. It comes in two halves: .claude/rules/dsl-reference.md,
# a short index that every session loads (a line per verb, pointing at its group), and
# .claude/dsl/<group>.md, the whole story of each group, read only when it is wanted.
# This walks the DSL verbs actually mixed into Builder right now and fails if any is
# missing from either half — the failure names the missing verb and says how to fix it.
# A crude but effective coverage check (it looks for the verb name as a word; it doesn't
# police the signature).
class TestDslReference < Minitest::Test
  SHEET = RubyGBA.root.join(".claude/rules/dsl-reference.md").to_s

  # The index is loaded into every session, so it is held to a line a verb. The cap is a
  # little over twice its size when it was split off, and well under the 150,000 characters
  # at which a session warns that a rules file is slowing it down. A paragraph belongs in a
  # group file.
  MOST_INDEX_CHARACTERS = 40_000

  include DslVerbs

  # Match the verb name as a whole word (so `set` isn't satisfied by `set_cell`).
  private def mentions?(text, verb) = text.match?(/(?<!\w)#{Regexp.escape(verb.to_s)}(?!\w)/)

  private def verbs_missing_from(text)
    dsl_verbs.reject { |verb| mentions?(text, verb) }
  end

  # Each section of the index with the group file its heading points at (nil where it
  # points at none), as [heading, text, path relative to the repository].
  private def index_sections
    File.read(SHEET).split(/^## /).drop(1).map do |section|
      heading = section.lines.first.strip
      [heading, section, heading[%r{\.claude/dsl/[\w-]+\.md}]]
    end
  end

  def test_every_dsl_verb_is_in_the_index
    # Guard against a broken enumeration silently passing this test (empty concerns
    # would leave only list/entry, which are trivially present).
    assert_operator dsl_verbs.length, :>, 40, "DSL verb enumeration looks broken (#{dsl_verbs.length} verbs)"

    missing = verbs_missing_from(File.read(SHEET))
    assert_empty missing, <<~MSG
      These DSL verbs are missing from .claude/rules/dsl-reference.md:
        #{missing.join(', ')}
      Add a line for each (a short signature, what it does in a sentence, and its group
      file), and the whole story to that group file under .claude/dsl/ — or, if it isn't
      really an authoring verb, add it to SKIP in test/dsl_verbs.rb with a note why.
    MSG
  end

  def test_every_section_of_the_index_points_at_a_group_file_that_is_there
    unpointed = index_sections.reject { |_, _, path| path }.map(&:first)
    assert_empty unpointed, "These sections of the index name no group file under .claude/dsl/: #{unpointed.join('; ')}"

    absent = index_sections.filter_map { |_, _, path| path unless File.exist?(RubyGBA.root.join(path)) }
    assert_empty absent, "The index points at group files that are not there: #{absent.join(', ')}"
  end

  # A verb's index line is in the section that points at its group file, so the verb has to
  # be told there and not merely somewhere.
  def test_every_dsl_verb_is_told_in_full_in_the_group_file_its_section_points_at
    missing = index_sections.flat_map do |_, text, path|
      next [] unless path && File.exist?(RubyGBA.root.join(path))

      group = File.read(RubyGBA.root.join(path))
      dsl_verbs.select { |verb| mentions?(text, verb) && !mentions?(group, verb) }.map { |verb| "#{verb} (#{path})" }
    end

    assert_empty missing, <<~MSG
      These DSL verbs are on an index line but not in the group file that section points at:
        #{missing.join(', ')}
      Tell each one in full in that group file, or move its line to the section it belongs in.
    MSG
  end

  def test_the_index_stays_short_enough_to_load_every_session
    size = File.read(SHEET).length
    assert_operator size, :<=, MOST_INDEX_CHARACTERS, <<~MSG
      .claude/rules/dsl-reference.md is #{size} characters, over #{MOST_INDEX_CHARACTERS}. Every
      session loads it, so keep each verb to a line there and put the rest in its group file.
    MSG
  end
end
