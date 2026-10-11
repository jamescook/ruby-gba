# frozen_string_literal: true

# Runs one program twice — in the interpreter, which is the answer key, and as C built with no
# window — and checks the two agree on every variable at every frame boundary and at the end.
#
# What is compared is what the windowless runtime prints (rg_headless.c): every variable the
# program names, at the start of each frame and when the run stops. The interpreter's answer is
# read at the same moments (each_vblank, and after run), and a variable it never wrote reads 0,
# which is also what the C starts every variable at.
module NativeComparison
  Native = RubyGBA::IR::Backends::Native
  Reference = RubyGBA::IR::Backends::Reference
  Builder = RubyGBA::Builder

  # Build a program through the DSL, the way the DSL tests do.
  def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # +buttons+ maps a frame number (from 1) to the buttons held during it. Gives back the
  # interpreter's variables at the end, so a test can also say the run did something worth
  # comparing — two runs that both left everything at 0 agree too.
  def assert_native_matches_reference(program, frames: 5, buttons: {})
    expected = reference_snapshots(program, frames: frames, buttons: buttons)
    %i[checked fast].each do |mode|
      actual = native_snapshots(program, frames: frames, buttons: buttons, mode: mode)
      assert_equal expected.map(&:first), actual.map(&:first), "the frame boundaries differ (#{mode} build)"
      expected.zip(actual).each do |(heading, want), (_, got)|
        wrong = got.filter_map { |name, value| "#{name}: C has #{value}, Reference #{want.fetch(name, 0)}" if want.fetch(name, 0) != value }
        assert_empty wrong, "at #{heading} (#{mode} build)"
      end
    end
    expected.last.last
  end

  # [[heading, { variable => value }], ...] as the windowless program printed them.
  def native_snapshots(program, frames:, buttons:, mode:)
    exe = Native.new.build_headless(program, mode: mode)
    input = (1..frames).map { |frame| "#{button_mask(buttons.fetch(frame, []))}\n" }.join
    parse_snapshots(Native::Zig.run_program(exe, args: [frames], input: input))
  end

  def reference_snapshots(program, frames:, buttons:)
    interpreter = Reference.new
    snapshots = []
    interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
               .each_vblank { |frame| snapshots << ["frame #{frame}", interpreter.vars.dup] }
               .run(program, frames: frames)
    snapshots << ["end", interpreter.vars.dup]
  end

  private

  def button_mask(held)
    Array(held).sum { |button| 1 << RubyGBA::IR::Buttons::NAMES.index(button) }
  end

  def parse_snapshots(text)
    text.lines.map(&:chomp).slice_before { |line| line.start_with?("frame ") || line == "end" }.map do |heading, *rows|
      [heading, rows.to_h { |row| name, value = row.split(" "); [name.to_sym, Integer(value)] }]
    end
  end
end
