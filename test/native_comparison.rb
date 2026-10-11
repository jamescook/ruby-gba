# frozen_string_literal: true

# Runs one program twice — in the interpreter, which is the answer key, and as C built with no
# window — and checks the two agree on every variable and every pixel of the picture shown, at
# every frame boundary and at the end.
#
# What is compared is what the windowless runtime prints (rg_headless.c): every variable the
# program names, and the picture, at the start of each frame and when the run stops. The
# interpreter's answer is read at the same moments (each_vblank, and after run), and a variable
# it never wrote reads 0, which is also what the C starts every variable at.
module NativeComparison
  Native = RubyGBA::IR::Backends::Native
  Reference = RubyGBA::IR::Backends::Reference
  Builder = RubyGBA::Builder
  WIDTH = RubyGBA::IR::Screen::WIDTH

  # One moment of a run: its heading ("frame 3", "end"), the variables, and the picture shown.
  Snapshot = Data.define(:heading, :variables, :picture)

  # Build a program through the DSL, the way the DSL tests do.
  def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # +buttons+ maps a frame number (from 1) to the buttons held during it. Gives back the
  # interpreter's last snapshot, so a test can also say the run did something worth comparing —
  # two runs that both left everything at 0 agree too.
  def assert_native_matches_reference(program, frames: 5, buttons: {}, modes: %i[checked fast])
    expected = reference_snapshots(program, frames: frames, buttons: buttons)
    modes.each do |mode|
      actual = native_snapshots(program, frames: frames, buttons: buttons, mode: mode)
      assert_equal expected.map(&:heading), actual.map(&:heading), "the frame boundaries differ (#{mode} build)"
      expected.zip(actual).each { |want, got| assert_same_moment(want, got, mode) }
    end
    expected.last
  end

  # The snapshots the windowless program printed.
  def native_snapshots(program, frames:, buttons:, mode:)
    exe = Native.new.build_headless(program, mode: mode)
    input = (1..frames).map { |frame| "#{button_mask(buttons.fetch(frame, []))}\n" }.join
    parse_snapshots(Native::Zig.run_program(exe, args: [frames], input: input))
  end

  def reference_snapshots(program, frames:, buttons:)
    interpreter = Reference.new
    snapshots = []
    interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
               .each_vblank { |frame| snapshots << reference_moment(interpreter, "frame #{frame}") }
               .run(program, frames: frames)
    snapshots << reference_moment(interpreter, "end")
  end

  private

  def reference_moment(interpreter, heading)
    Snapshot.new(heading: heading, variables: interpreter.vars.dup, picture: interpreter.screen.shown)
  end

  def assert_same_moment(want, got, mode)
    # Both ways: a variable the interpreter wrote and the C never printed is a variable the
    # lowering lost track of, which comparing only what the C printed would never notice.
    unprinted = want.variables.keys - got.variables.keys
    assert_empty unprinted, "the C does not keep these variables the interpreter wrote (#{mode} build)"
    wrong = got.variables.filter_map do |name, value|
      expected = want.variables.fetch(name, 0)
      "#{name}: C has #{value}, Reference #{expected}" if expected != value
    end
    assert_empty wrong, "at #{got.heading} (#{mode} build)"
    assert_same_picture(want.picture, got.picture, "at #{got.heading} (#{mode} build)")
  end

  def assert_same_picture(want, got, where)
    return if want == got

    first = want.each_index.find { |i| want[i] != got[i] }
    differing = want.each_index.count { |i| want[i] != got[i] }
    flunk "the pictures differ #{where}: #{differing} pixels, the first at " \
          "(#{first % WIDTH}, #{first / WIDTH}): C shows #{format('%04x', got[first])}, " \
          "Reference #{format('%04x', want[first])}"
  end

  def button_mask(held)
    Array(held).sum { |button| 1 << RubyGBA::IR::Buttons::NAMES.index(button) }
  end

  def parse_snapshots(text)
    text.lines.map(&:chomp).slice_before { |line| line.start_with?("frame ") || line == "end" }.map do |heading, *rows|
      picture_line = rows.find { |row| row.start_with?("picture ") }
      variables = (rows - [picture_line]).to_h { |row| name, value = row.split(" "); [name.to_sym, Integer(value)] }
      picture = picture_line.delete_prefix("picture ").scan(/\h{4}/).map { |hex| hex.to_i(16) }
      Snapshot.new(heading: heading, variables: variables, picture: picture)
    end
  end
end
