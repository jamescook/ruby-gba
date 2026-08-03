# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# rom.explain prints a cost heatmap through a printer adapter: PlainPrinter reproduces
# the exact pre-colour output (for a pipe, a file, or a captured StringIO), ColorPrinter
# tints each line by how much of the frame budget it uses and marks a group heading bold
# + underlined. The severity→colour thresholds live in one place and key off the budget,
# so a red line and the "over budget" verdict can never disagree. Colours auto-disable
# off a terminal and under NO_COLOR, and can be forced either way.
class TestCostPrinter < Minitest::Test
  include RubyGBA::IR::Build

  Printer = RubyGBA::IR::Printer
  Plain = RubyGBA::IR::PlainPrinter
  Color = RubyGBA::IR::ColorPrinter
  Cost = RubyGBA::IR::CostModel

  # A stand-in for an interactive terminal (a StringIO is not a TTY).
  class FakeTTY < StringIO
    def tty? = true
  end

  def strip(text) = text.gsub(/\e\[[0-9;]*m/, "")

  def plain_line(label, value)
    io = StringIO.new
    Plain.new(io).cost_line(label, value)
    io.string.chomp
  end

  # --- the factory: when do colours turn on? ---

  def test_for_defaults_to_plain_off_a_terminal
    assert_instance_of Plain, Printer.for(StringIO.new)
  end

  def test_for_colours_a_terminal_by_default
    with_env("NO_COLOR", nil) { assert_instance_of Color, Printer.for(FakeTTY.new) }
  end

  def test_no_color_env_forces_plain_even_on_a_terminal
    with_env("NO_COLOR", "1") { assert_instance_of Plain, Printer.for(FakeTTY.new) }
  end

  def test_color_true_forces_colour_off_a_terminal
    assert_instance_of Color, Printer.for(StringIO.new, color: true)
  end

  def test_color_false_forces_plain_on_a_terminal
    with_env("NO_COLOR", nil) { assert_instance_of Plain, Printer.for(FakeTTY.new, color: false) }
  end

  # --- plain printer: verbatim, no escapes ---

  def test_plain_puts_ignores_severity_and_emphasis
    io = StringIO.new
    Plain.new(io).puts("hello", severity: :hot, emphasis: :banner)
    assert_equal "hello\n", io.string
  end

  def test_plain_cost_line_is_the_aligned_layout_with_no_escapes
    io = StringIO.new
    Plain.new(io).cost_line("set ×3", "1.2", severity: :hot, group: true)
    refute_includes io.string, "\e", "the plain printer never emits colour"
    assert io.string.start_with?("  set ×3"), "the label leads the line"
    assert io.string.chomp.end_with?("~1.2"), "the value trails it"
    assert_equal 2 + Printer::LABEL_WIDTH + 2 + "1.2".length, io.string.chomp.length, "value column is aligned"
  end

  # --- colour printer ---

  def test_colour_puts_wraps_the_line_in_the_severity_colour
    io = StringIO.new
    Color.new(io).puts("warm line", severity: :warm)
    assert_equal "#{Color::COLORS[:warm]}warm line#{Color::RESET}\n", io.string
  end

  def test_colour_banner_is_bold_red
    io = StringIO.new
    Color.new(io).puts("!! can't estimate", emphasis: :banner)
    assert io.string.start_with?(Color::EMPHASIS[:banner])
    assert io.string.end_with?("#{Color::RESET}\n")
  end

  def test_colour_cost_line_tints_the_whole_row_but_adds_only_zero_width_codes
    io = StringIO.new
    Color.new(io).cost_line("fill_rect", "5.0", severity: :hot)
    assert io.string.start_with?(Color::COLORS[:hot])
    assert io.string.end_with?("#{Color::RESET}\n")
    assert_equal plain_line("fill_rect", "5.0"), strip(io.string).chomp, "same text as plain, just tinted"
  end

  # A group heading: bold + underline, but the underline stops right after the label —
  # it must NOT run across the padding to the value column (the reported footgun).
  def test_colour_group_heading_underlines_only_the_indent_and_label
    io = StringIO.new
    Color.new(io).cost_line("  player.rb", "0.1", severity: :good, group: true)
    line = io.string
    assert_includes line, Color::BOLD, "a heading is bold"

    on = line.index(Color::UNDERLINE)
    off = line.index(Color::UNDERLINE_OFF)
    value_at = line.index("~0.1")
    assert on && off, "the heading is underlined"
    assert off < value_at, "the underline is turned off before the value column"

    underlined = line[(on + Color::UNDERLINE.length)...off]
    assert_equal "    player.rb", underlined, "only the lead + label is underlined (indent included)"
    assert_equal plain_line("  player.rb", "0.1"), strip(line).chomp, "same text as plain"
  end

  # --- integration: colour agrees with the verdict; the disable path is byte-for-byte ---

  def over_budget_program
    program(screen(:bitmap), loop_(wait_vblank, *Array.new(60) { fill_rect(0, 0, 40, 40, :red) }, halt))
  end

  def cheap_program
    program(screen(:bitmap), loop_(wait_vblank, fill_rect(0, 0, 40, 40, :red), halt))
  end

  # A frame whose only work is inside a loop counted at run time (a plain variable, no
  # provable bound) — so the static estimate prices it at zero and can't vouch for it.
  def blind_program
    program(screen(:bitmap), loop_(wait_vblank, repeat(var_ref(:n), :i, fill_rect(0, 0, 40, 40, :red)), halt))
  end

  def rendered(prog, **opts)
    io = StringIO.new
    Cost.new.render(prog, out: io, **opts)
    io.string
  end

  # The frame budget line in the bottom budget summary — where the frame verdict lives.
  def verdict_line(text)
    text.lines.find { |line| line =~ /estimate (within|over) budget/ }
  end

  def test_an_over_budget_frame_paints_the_verdict_red
    line = verdict_line(rendered(over_budget_program, color: true))
    assert_includes line, Color::COLORS[:hot]
    assert_includes line, "over budget", "colour and verdict agree: both say over"
  end

  def test_a_cheap_frame_paints_the_verdict_green
    line = verdict_line(rendered(cheap_program, color: true))
    assert_includes line, Color::COLORS[:good]
    assert_includes line, "estimate within budget"
  end

  # The heart of the DX decision: a game that FITS shows no red anywhere — red is the
  # "you're over budget" alarm, never a hotspot label. So a fitting program's drill-down
  # stays green→orange, and the reader isn't told to fix a game that's fine.
  # With nothing measured, the verdict is a static estimate: it reads as within/over
  # budget, promises no frame rate, and says plainly that it did not run the game.
  def test_the_verdict_reads_as_an_estimate_when_nothing_measured_it
    output = rendered(cheap_program)
    refute_includes output, "holds 60fps", "no frame rate is promised — the cost model only estimates"
    assert_includes output, "estimate within budget"
    assert_includes output, "estimate only", "says it is an estimate, not a measurement"
    refute_includes output, "--analyze", "the analyze flag is gone; explain measures on its own"
  end

  # The honesty fix: a measurement, when present, IS the verdict — the estimate's own
  # within/over verdict is suppressed, so the two can never disagree in the report.
  def test_a_measurement_becomes_the_verdict_and_suppresses_the_estimate
    fits = rendered(cheap_program, measured: { nil => { scanlines: 30.0, fps: nil, saturated: false } })
    assert_includes fits, "measured ~30", "the measured cost is the verdict"
    refute_includes fits, "estimate within budget", "the estimate verdict is suppressed once measured"
    refute_includes fits, "estimate only", "no estimate-only hint when a measurement is in hand"

    over = rendered(cheap_program, measured: { nil => { scanlines: 220.0, fps: 18.0, saturated: true } })
    assert_includes over, "measured over budget", "a saturated frame reads over budget"
    assert_includes over, "18.0 fps", "with the measured frame rate"
  end

  # Estimate-only, and the frame has an unbounded loop the model can't size: it must NOT
  # claim "within budget" — the estimate says it can't tell.
  def test_a_blind_spot_stops_the_estimate_claiming_within_budget
    output = rendered(blind_program)
    refute_includes output, "estimate within budget", "an unbounded loop can hide real cost"
    assert_includes output, "estimate can't tell", "the estimate admits it can't size the loop"
    assert_includes output, "unbounded loop"
  end

  def test_a_fitting_program_has_no_red_anywhere
    output = rendered(cheap_program, color: true)
    assert_includes verdict_line(output), "estimate within budget"
    refute_includes output, Color::COLORS[:hot], "nothing is red when the frame fits"
  end

  # Even when the program IS over budget, red belongs only to the alarm lines (the
  # budget verdict / the unpriced banner) — never to a tree row or the roll-up total,
  # which only grade where the time goes. A big one-off is orange, not red.
  def test_red_is_confined_to_alarm_lines_not_the_tree
    output = rendered(over_budget_program, color: true)
    red_lines = output.lines.select { |line| line.include?(Color::COLORS[:hot]) }
    refute_empty red_lines, "an over-budget program does raise the alarm somewhere"
    red_lines.each do |line|
      assert line.include?("over budget") || line.include?("tears") || line.include?("can't estimate"),
             "red only on an alarm line, got a tree row: #{line.inspect}"
    end
  end

  def test_color_false_yields_no_escapes_and_matches_the_stripped_colour_output
    plain = rendered(over_budget_program, color: false)
    colored = rendered(over_budget_program, color: true)
    refute_includes plain, "\e", "color:false emits plain text"
    assert_equal plain, strip(colored), "colour only adds zero-width codes — identical text"
  end

  def test_auto_off_for_a_captured_stringio_equals_forced_plain
    assert_equal rendered(over_budget_program, color: false), rendered(over_budget_program),
                 "a captured StringIO is not a TTY, so :auto stays plain"
  end

  private

  def with_env(key, value)
    had = ENV.key?(key)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    had ? (ENV[key] = old) : ENV.delete(key)
  end
end
