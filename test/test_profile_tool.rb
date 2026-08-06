# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../tools/profile"

# The profile tool (tools/profile.rb, `rake profile`): build every example twice —
# once against the working tree's library and once against an older one — and say
# what moved.
#
# What is asserted here is the part with decisions in it: turning two measurements
# of one program into a verdict, and the report a person reads. Those are plain
# objects with no git, no subprocess and no filesystem behind them, so this file
# costs milliseconds.
#
# The git side (lay an old library into a temp directory) is deliberately NOT
# asserted. It is two commands with no decisions in them, so a test of it would be
# a test of git — and it would need git installed to say anything at all. The tool
# itself is how we know that part works.
class TestProfileTool < Minitest::Test
  Measurement = Profile::Measurement
  Row = Profile::Row
  Report = Profile::Report

  INSTRUCTION = Profile::BYTES_PER_INSTRUCTION

  # An example that built, sized in instructions so the tests read in the unit the
  # report speaks.
  def built(name, instructions:, data: 0, frame: 0.0)
    Measurement.new(name: name, title: name.upcase, code: instructions * INSTRUCTION,
                    data: data, frame: frame, error: nil)
  end

  def failed(name, error: "NoMethodError: undefined method 'fade'")
    Measurement.new(name: name, title: nil, code: nil, data: nil, frame: nil, error: error)
  end

  def row(name, before, after) = Row.new(name: name, before: before, after: after)

  # One example that grew by +instructions+ between the two sides.
  def grew_by(name, instructions, from: 1000, data: 0, frame: 0.0)
    row(name, built(name, instructions: from, data: data, frame: frame),
        built(name, instructions: from + instructions, data: data, frame: frame))
  end

  def render(rows)
    out = StringIO.new
    Report.new(Array(rows), ref: "HEAD (abc1234)").render(out)
    out.string
  end

  def summary(rows) = Report.new(Array(rows), ref: "HEAD (abc1234)").summary

  # ---- the answer you get when nothing moved ----

  def test_the_same_program_compiled_twice_reports_as_identical
    rows = [grew_by("pong", 0), grew_by("snake", 0)]

    assert_match(/identical/, summary(rows))
    assert_match(/2 unchanged/, render(rows), "every example is still accounted for")
  end

  # ---- a change to the lowering ----

  def test_extra_instructions_get_a_row_and_a_total
    rows = [grew_by("pong", 18, from: 4000)]
    report = render(rows)

    assert_match(/pong/, report)
    assert_match(/\+18/, report, "reported in instructions, the unit a lowering change is thought about in")
    assert_match(/code \+18 instructions/, summary(rows))
  end

  def test_a_shrinking_program_reads_as_a_saving
    assert_match(/code -12 instructions/, summary([grew_by("pong", -12, from: 4000)]))
  end

  # ---- the three numbers are three numbers ----

  # A new sprite sheet is twenty kilobytes and not one extra instruction. Rolled
  # into one total that would read as a compiler change.
  def test_assets_are_counted_apart_from_the_code
    rows = [row("pacman", built("pacman", instructions: 4000, data: 3908),
                built("pacman", instructions: 4000, data: 24_288))]

    assert_match(/code unchanged/, summary(rows))
    assert_match(/data \+20380 bytes/, summary(rows))
  end

  # The clamp case: making a bound something the game works out cost thirty
  # instructions of ROM and nothing at all per frame. One number could not say that.
  def test_code_can_grow_while_the_frame_stays_free
    rows = [grew_by("breakout", 30, from: 4000, frame: 41.2)]

    assert_match(/code \+30 instructions/, summary(rows))
    assert_match(/frame work unchanged/, summary(rows))
  end

  def test_frame_work_is_reported_where_it_moved
    rows = [grew_by("pong", 0, from: 4000),
            row("shmup", built("shmup", instructions: 6000, frame: 227.6),
                built("shmup", instructions: 6000, frame: 232.3))]

    assert_match(/frame work \+4\.7 scanlines at worst \(shmup\)/, summary(rows))
  end

  # ---- what gets a row ----

  def test_a_single_instruction_is_counted_but_not_given_a_row
    report = render([grew_by("pong", 1, from: 4000), grew_by("snake", 0)])

    refute_match(/example\s+code/, report, "one instruction is not worth a table")
    assert_match(/noise floor \(pong\)/, report, "but it is never dropped silently")
  end

  # A hundred instructions on the smallest program is the interesting one, even
  # though the biggest program is where most of the bytes are.
  def test_rows_are_ranked_by_how_far_they_moved_not_by_size
    rows = [grew_by("shmup", 6, from: 6000), grew_by("pixels", 100, from: 200)]
    listed = render(rows).lines.grep(/pixels|shmup/).map { |line| line.split.first }

    assert_equal %w[pixels shmup], listed
  end

  # ---- a program that builds on only one side ----

  def test_an_example_that_only_builds_now_is_reported_as_new
    report = render([row("bird", failed("bird"), built("bird", instructions: 600))])

    assert_match(/bird/, report)
    assert_match(/only builds on the working tree/, report)
  end

  def test_an_example_that_stopped_building_leads_the_report
    rows = [grew_by("pong", 4, from: 4000),
            row("bird", built("bird", instructions: 600), failed("bird", error: "boom"))]
    report = render(rows)

    assert_match(/bird/, report.lines.first, "the regression is the first thing said")
    assert_match(/boom/, report, "with what it said on the way out")
    assert_match(/NO LONGER BUILDS \(bird\)/, summary(rows))
    assert_match(/code \+4 instructions/, summary(rows), "and the rest is still measured")
  end

  def test_an_example_that_builds_on_neither_side_is_not_a_regression
    rows = [row("bird", failed("bird"), failed("bird"))]

    refute_match(/NO LONGER BUILDS/, summary(rows), "it was already broken; that is not news")
    assert_match(/does not build on either side/, render(rows))
  end

  # ---- the escape hatch can emit bytes that are not whole instructions ----

  def test_a_delta_that_is_not_whole_instructions_is_reported_in_bytes
    rows = [row("raw", Measurement.new(name: "raw", title: "RAW", code: 400, data: 0, frame: 0.0, error: nil),
                Measurement.new(name: "raw", title: "RAW", code: 406, data: 0, frame: 0.0, error: nil))]

    assert_match(/\+6 B/, render(rows), "six bytes is not an instruction count, so it says bytes")
  end

  # ---- what came back from the child process ----

  def test_a_probe_that_reported_becomes_a_measurement
    m = Profile.measurement("pong", %({"name":"pong","title":"PONG","code":400,"data":16,"frame":12.5}\n))

    assert_predicate m, :ok?
    assert_equal 400, m.code
    assert_in_delta 12.5, m.frame
  end

  def test_a_probe_that_died_reports_its_last_words_instead_of_crashing
    m = Profile.measurement("pong", "", "some_file.rb:12:in 'lower': undefined method 'fade'\n")

    refute_predicate m, :ok?
    assert_match(/undefined method 'fade'/, m.error)
  end

  def test_a_probe_that_died_silently_still_says_something
    m = Profile.measurement("pong", "", "")

    refute_predicate m, :ok?
    refute_empty m.error.to_s
  end

  # ---- the one assertion that costs something ----

  # Every number this tool prints rests on one thing: the example was built against
  # the library the probe was pointed at. An example asks for the library by
  # relative path, and if that request were ever honoured, both sides would build
  # against the working tree — so the tool would report "identical" for ever while
  # looking perfectly healthy. Nothing above can catch that.
  #
  # A cheaper stand-in cannot catch it either. Whichever copy of the library loads
  # LAST wins, so a patch applied by a shim (or through a tree of symlinks) would
  # survive the working tree loading over it and the test would pass either way.
  # Only a real second copy can be overwritten, and being able to fail is the whole
  # point. So: one copy of lib/, about a megabyte and fifty milliseconds, once for
  # the suite, in a temp directory that removes itself.
  #
  # The copy is made to emit four bytes more than the original, so a measurement
  # says which copy produced it.
  MARKER = <<~RUBY
    module RubyGBA
      module IR
        module Backends
          class GBA
            alias_method :__lower_before_marker, :lower
            def lower(program)
              __lower_before_marker(program) + ("\\x00" * 4)
            end
          end
        end
      end
    end
  RUBY

  def test_the_probe_measures_the_library_it_is_pointed_at
    example = Profile.examples("pixels").first
    refute_nil example, "the tool finds the example programs"

    plain = Profile.probe(File.join(Profile::ROOT, "lib"), example)
    assert_predicate plain, :ok?, "the working tree builds it: #{plain.error}"

    Dir.mktmpdir("profile-isolation") do |dir|
      FileUtils.cp_r File.join(Profile::ROOT, "lib"), dir
      entry = File.join(dir, "lib", "ruby_gba.rb")
      File.write entry, File.read(entry) + MARKER

      marked = Profile.probe(File.join(dir, "lib"), example)
      assert_predicate marked, :ok?, "the copy builds it too: #{marked.error}"
      assert_equal emitted(plain) + 4, emitted(marked),
                   "the measurement came from the library the probe was given, " \
                   "not the one the example asks for"
    end
  end

  def emitted(measurement) = measurement.code + measurement.data
end
