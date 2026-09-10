# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# rom.profile(format: :json): the same facts as the prose report, as data, for something that
# is going to compare two builds rather than read one. The prose is the teaching surface and
# is free to change; nothing comparing builds should be pinned to a sentence of it.
#
# So every assertion here reads a field and never matches a word of the report.
#
# WHAT IS NO LONGER HERE, and it is the point of the change: a frame priced in scanlines, the
# budget it was judged against, and a verdict of over or under. Those were the estimate's, and
# the estimate is gone. What is left is two kinds of fact — what the build made, and what the
# run counted.
class TestProfileJson < Minitest::Test
  include GembaSupport

  def setup
    require_gemba_core!
  end

  def build(title, code, &block)
    RubyGBA.build(title, code: code, maker: "01", out: StringIO.new, err: StringIO.new, &block)
  end

  def light
    build("LIGHT", "ZLGT") do
      screen :bitmap
      game_loop { fill_rect 0, 0, 40, 8, :green }
    end
  end

  # Draws far more than fits in the gap between frames, AND draws something DIFFERENT each
  # frame — a tear is the display showing a row before the game finished it, so a picture that
  # repaints itself the same colour every frame has no seam to see even when it overruns.
  def heavy
    build("HEAVY", "ZHVY") do
      screen :bitmap
      c = var :c, 0
      game_loop do
        c.set(1 - c)
        (c == 0).then { fill_rect 0, 0, 240, 120, :red }
        (c == 1).then { fill_rect 0, 0, 240, 120, :blue }
      end
    end
  end

  def json_of(rom, **opts)
    io = StringIO.new
    rom.profile(format: :json, out: io, frames: 10, **opts)
    JSON.parse(io.string)
  end

  # THE ACCEPTANCE: two builds compared without matching any prose. What separates them now
  # is what the console really did, not what a model said it would do.
  def test_two_builds_compare_on_their_numbers_alone
    a = json_of(light)
    b = json_of(heavy)

    assert_operator a["idle_share"], :>, b["idle_share"],
                    "the heavy one has less of each frame left over"
    assert_operator a["fps"], :>=, b["fps"]
  end

  # What the quick memory kept and passed over, with sizes — the numbers the prose prints, and
  # the ones a before-and-after wants: did the routine that just missed now fit.
  def test_the_quick_memory_is_reported_with_sizes_and_the_names_a_person_uses
    memory = json_of(light)["quick_memory"]

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

  # Where the frames went, per routine, and how the moment being measured was reached — a
  # profile without the second is not reproducible.
  def test_the_measured_half_is_data_too
    json = json_of(light)

    assert_equal 10, json["frames"]
    assert_operator json["routines"].first["share"], :>, 0
    assert_equal "boot", json["reached"]["how"]
  end

  # A single-buffered game is looked at for a tear; one that cannot tear reports nothing,
  # because "we did not look" must never read as "nothing was wrong".
  def test_tearing_is_data_when_it_could_be_looked_for
    assert_operator json_of(heavy)["tearing"]["torn"], :>, 0

    buffered = build("BUFF", "ZBUF") do
      screen :bitmap, tear_free: true
      game_loop { clear_screen :black }
    end

    assert_nil json_of(buffered)["tearing"]
  end

  def test_it_states_no_frame_cost_and_no_budget
    json = json_of(heavy)

    assert_nil json["frame_cost"]
    assert_nil json["frame_budget"]
    assert_nil json["steady_cost"]
  end
end
