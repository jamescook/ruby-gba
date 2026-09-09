# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# rom.explain(format: :json): the same facts as the prose report, as data, for something that
# is going to compare two builds rather than read one. The prose is the teaching surface and
# is free to change; nothing comparing builds should be pinned to a sentence of it.
#
# So every assertion here reads a field and never matches a word of the report.
class TestExplainJson < Minitest::Test
  def build(title, code, &block)
    RubyGBA.build(title, code: code, maker: "01", out: StringIO.new, err: StringIO.new, &block)
  end

  def light
    build("LIGHT", "ZLGT") do
      screen :bitmap
      game_loop { fill_rect 0, 0, 40, 8, :green }
    end
  end

  def heavy
    build("HEAVY", "ZHVY") do
      screen :bitmap
      game_loop { repeat(100) { |_i| clear_screen :black } }
    end
  end

  def json_of(rom, **opts)
    io = StringIO.new
    rom.explain(format: :json, out: io, **opts)
    JSON.parse(io.string)
  end

  # THE ACCEPTANCE: two builds compared without matching any prose.
  def test_two_builds_compare_on_their_numbers_alone
    a = json_of(light)
    b = json_of(heavy)

    assert_operator a["frame_cost"], :<, b["frame_cost"]
    assert_operator a["steady_cost"], :<=, a["frame_budget"]
    assert_operator b["steady_cost"], :>, b["frame_budget"]
    assert_equal a["frame_budget"], b["frame_budget"]
  end

  # What the quick memory kept and passed over, with sizes — the numbers the prose report
  # prints, and the ones a before-and-after wants: did the routine that just missed now fit.
  def test_the_quick_memory_is_reported_with_sizes_and_the_names_a_person_uses
    memory = json_of(light)["quick_memory"]

    assert_equal 32 * 1024, memory["total_bytes"]
    assert_operator memory["used_bytes"] + memory["free_bytes"], :<=, memory["total_bytes"]
    kept = memory["kept"].find { |r| r["name"] == "__frame" }
    refute_nil kept, "the game loop's body is kept"
    assert_equal "the game loop", kept["label"]
    assert_operator kept["bytes"], :>, 0
    assert_kind_of Array, memory["passed_over"]
  end

  # The guardrails' findings ride along, each with its check, severity and the author's line,
  # so a before-and-after can ask "did the warning go away" without reading it.
  def test_the_findings_ride_along_as_data
    findings = json_of(heavy)["findings"]

    over = findings.find { |f| f["check"] == "draw_budget" }
    refute_nil over
    assert_equal "warning", over["severity"]
    assert_match(/\.rb:\d+/, over["at"])
    assert_empty json_of(light)["findings"]
  end

  # The measured verdict, when one was asked for: per scene, or under "frame", each with
  # whether it is over budget — and when none was, why not.
  def test_a_measured_verdict_is_data_too_and_says_when_there_is_none
    unasked = json_of(light)
    assert_nil unasked["measured"]
    assert_equal "not_asked", unasked["unmeasured"]

    measured = json_of(light, measured: true)
    frame = measured["measured"]["frame"]
    assert_operator frame["scanlines"], :>, 0
    assert_equal false, frame["over"]
    assert_nil measured["unmeasured"]
  end
end
