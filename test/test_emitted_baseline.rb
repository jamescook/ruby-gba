# frozen_string_literal: true

require "test_helper"

require "stringio"
require "tmpdir"
require_relative "../tools/emitted_baseline"

# The recorded size of every example, and the check that nothing grew past it
# (tools/emitted_baseline.rb, `rake emitted:record` / `rake emitted:check`).
#
# The comparison is a pure function of two maps, so these build the maps by hand and
# never compile anything. Measuring the real corpus takes about three seconds, which
# is what the rake task is for; it is not something the suite should pay on every run.
class TestEmittedBaseline < Minitest::Test
  Baseline = Emitted::Baseline
  Verdict = Emitted::Baseline::Verdict

  def sizes(**examples)
    examples.to_h { |name, (code, data)| [name.to_s, { code: code, data: data.to_i }] }
  end

  def verdict(recorded, measured, errors: {})
    Verdict.new(recorded: recorded, measured: measured, errors: errors)
  end

  def render(v)
    out = StringIO.new
    v.render(out)
    out.string
  end

  # ---- the thing it is for ----

  def test_code_that_grew_fails_and_says_by_how_much
    v = verdict(sizes(pong: [4000]), sizes(pong: [4072]))

    refute_predicate v, :ok?
    report = render(v)
    assert_match(/grown past the recorded baseline/, report)
    assert_match(/pong/, report)
    assert_match(/\+18 instructions/, report)
  end

  # A ratchet nobody can act on gets switched off, so the failure has to carry the
  # cure — and the cure has to be one command.
  def test_the_failure_says_how_to_accept_the_new_numbers
    report = render(verdict(sizes(pong: [4000]), sizes(pong: [4072])))

    assert_match(/rake emitted:record/, report)
    assert_match(/emitted_baseline\.json/, report)
  end

  def test_assets_that_grew_fail_too
    v = verdict(sizes(pacman: [4000, 3908]), sizes(pacman: [4000, 24_288]))

    refute_predicate v, :ok?
    assert_match(/data 3908 → 24288/, render(v))
  end

  def test_matching_the_baseline_passes
    v = verdict(sizes(pong: [4000], snake: [900, 32]), sizes(pong: [4000], snake: [900, 32]))

    assert_predicate v, :ok?
    assert_match(/within the recorded baseline/, render(v))
  end

  # Per example, because one total would let a program that shrank pay for one that
  # grew and the whole thing would look fine.
  def test_a_program_that_shrank_does_not_pay_for_one_that_grew
    v = verdict(sizes(pong: [4000], snake: [4000]),
                sizes(pong: [4400], snake: [3600])) # +400 and -400: nil overall

    refute_predicate v, :ok?
    assert_match(/pong/, render(v))
  end

  # ---- shrinking is the good direction ----

  def test_code_that_shrank_passes_but_is_mentioned
    v = verdict(sizes(pong: [4000]), sizes(pong: [3928]))

    assert_predicate v, :ok?
    assert_match(/Smaller than recorded/, render(v))
  end

  # ---- the corpus changing ----

  # An example nobody recorded is not covered by the ratchet at all, so it fails
  # until it is — the same one-command fix as any other failure.
  def test_an_unrecorded_example_fails
    v = verdict(sizes(pong: [4000]), sizes(pong: [4000], newcomer: [500]))

    refute_predicate v, :ok?
    report = render(v)
    assert_match(/Not in the baseline at all: newcomer/, report)
    assert_match(/rake emitted:record/, report)
  end

  # Deleting an example is not a regression.
  def test_an_example_that_is_gone_is_mentioned_but_passes
    v = verdict(sizes(pong: [4000], old: [500]), sizes(pong: [4000]))

    assert_predicate v, :ok?
    assert_match(/no longer present: old/, render(v))
  end

  def test_an_example_that_does_not_build_fails
    v = verdict(sizes(pong: [4000]), sizes(pong: [4000]), errors: { "bird" => "boom" })

    refute_predicate v, :ok?
    assert_match(/bird does not build: boom/, render(v))
  end

  # ---- the file ----

  def test_the_file_round_trips
    Dir.mktmpdir("emitted-baseline") do |dir|
      path = File.join(dir, "baseline.json")
      recorded = sizes(pong: [4000, 16], animate: [900])
      Baseline.write(path, recorded)

      assert_equal recorded, Baseline.read(path)
    end
  end

  # It is checked in so its diff can be reviewed, which needs a stable order and
  # one number per line — a re-record that reshuffled the file would bury the
  # change that matters in noise.
  def test_the_file_is_ordered_and_readable
    Dir.mktmpdir("emitted-baseline") do |dir|
      path = File.join(dir, "baseline.json")
      Baseline.write(path, sizes(zebra: [1], alpha: [2], middle: [3]))
      text = File.read(path)

      assert_operator text.index("alpha"), :<, text.index("middle")
      assert_operator text.index("middle"), :<, text.index("zebra")
      assert_match(/^\s+"code": 2,$/, text, "one field per line, so a diff points at the number")
    end
  end

  def test_a_missing_or_unreadable_file_reads_as_no_baseline
    Dir.mktmpdir("emitted-baseline") do |dir|
      assert_empty Baseline.read(File.join(dir, "nothing.json"))

      broken = File.join(dir, "broken.json")
      File.write(broken, "{not json")
      assert_empty Baseline.read(broken)
    end
  end

  # ---- the baseline that ships ----

  # The recorded file has to cover the examples that exist, or the ratchet is
  # quietly guarding a subset. This compares names only — the numbers themselves are
  # what `rake emitted:check` builds and verifies.
  def test_the_checked_in_baseline_covers_every_example
    recorded = Baseline.read
    refute_empty recorded, "tools/emitted_baseline.json is missing — run rake emitted:record"

    expected = Emitted.examples.map { |path| File.basename(path, ".rb") }.sort
    assert_equal expected, recorded.keys.sort,
                 "the baseline and the examples have drifted apart — run rake emitted:record"
  end
end
