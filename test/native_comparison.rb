# frozen_string_literal: true

# Runs one program twice — in the interpreter, which is the answer key, and as C built with no
# window — and checks the two agree on every variable, every pixel of the picture shown and every
# entry of the sound log, at every frame boundary and at the end.
#
# What is compared is what the windowless runtime prints (rg_headless.c): every variable the
# program names, the picture, and the sound log as it grows, at the start of each frame and when
# the run stops. The interpreter's answer is read at the same moments (each_vblank, and after
# run), and a variable it never wrote reads 0, which is also what the C starts every variable at.
module NativeComparison
  Native = RubyGBA::IR::Backends::Native
  Reference = RubyGBA::IR::Backends::Reference
  Builder = RubyGBA::Builder
  WIDTH = RubyGBA::IR::Screen::WIDTH

  # One moment of a run: its heading ("frame 3", "end"), the variables, the picture shown, and
  # the sound log up to then.
  Snapshot = Data.define(:heading, :variables, :picture, :sounds)

  # Buttons held the way a person holds them — one button through a run of frames at a time —
  # as the map of frame to buttons the comparisons take:
  #
  #   NativeComparison.held_for([10..15, :down], [30..38, :a])
  def self.held_for(*spans)
    spans.flat_map { |frames, button| frames.map { |frame| [frame, [button]] } }.to_h
  end

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
  def assert_native_matches_reference(program, frames: 5, buttons: {})
    expected = reference_snapshots(program, frames: frames, buttons: buttons)
    %i[checked fast].each do |mode|
      actual = native_snapshots(program, frames: frames, buttons: buttons, mode: mode)
      assert_equal expected.map(&:heading), actual.map(&:heading), "the frame boundaries differ (#{mode} build)"
      expected.zip(actual).each { |want, got| assert_same_moment(want, got, mode) }
    end
    expected.last
  end

  # The snapshots the windowless program printed.
  def native_snapshots(program, frames:, buttons:, mode:)
    exe = Native.new.build_headless(program, mode: mode)
    input = (1..frames).map { |frame| "#{Native::HeadlessRun.button_mask(buttons.fetch(frame, []))}\n" }.join
    parse_snapshots(Native::Zig.run_program(exe, args: [frames, "--every-picture"], input: input), program)
  end

  def reference_snapshots(program, frames:, buttons:)
    interpreter = Reference.new
    snapshots = []
    interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
               .each_vblank { |frame| snapshots << reference_moment(interpreter, "frame #{frame}") }
               .run(program, frames: frames)
    snapshots << reference_moment(interpreter, "end")
  end

  # The first entry of the sound log the two disagree on, or nil when every entry is the same.
  def sounds_difference(want, got)
    at = (0...[want.size, got.size].max).find { |index| want[index] != got[index] }
    at && "entry #{at} of the sound log: C has #{got[at].inspect}, Reference #{want[at].inspect}"
  end

  private

  def reference_moment(interpreter, heading)
    Snapshot.new(heading: heading, variables: interpreter.vars.dup, picture: interpreter.screen.shown,
                 sounds: interpreter.audio.dup)
  end

  # Everything that differs at one moment, said together: a wrong variable usually explains a
  # wrong picture, and seeing both at once says which.
  def assert_same_moment(want, got, mode)
    differences = variable_differences(want.variables, got.variables) +
                  [picture_difference(want.picture, got.picture), sounds_difference(want.sounds, got.sounds)].compact
    assert_empty differences, "at #{got.heading} (#{mode} build)"
  end

  # Every variable the two disagree on, said as "name: C has 2, Reference 1". Both ways: a
  # variable the interpreter wrote and the C never printed is a variable the lowering lost track
  # of, which comparing only what the C printed would never notice.
  def variable_differences(want, got)
    unprinted = (want.keys - got.keys).map { |name| "#{name}: the C does not keep it" }
    wrong = got.filter_map do |name, value|
      expected = want.fetch(name, 0)
      "#{name}: C has #{value}, Reference #{expected}" if expected != value
    end
    unprinted + wrong
  end

  def picture_difference(want, got)
    return nil if want == got

    first = want.each_index.find { |i| want[i] != got[i] }
    differing = want.each_index.count { |i| want[i] != got[i] }
    "the pictures differ in #{differing} pixels, the first at (#{first % WIDTH}, #{first / WIDTH}): " \
      "C shows #{format('%04x', got[first])}, Reference #{format('%04x', want[first])}"
  end

  # The program's printed moments. A sound line belongs to the log as it grows, so each moment
  # holds the log up to its own heading — which is where the interpreter's each_vblank reads it.
  def parse_snapshots(text, program)
    sound_log = Native::SoundLog.new(program)
    sounds = []
    moments = []
    text.each_line(chomp: true) do |line|
      if line.start_with?("sound ")
        sounds << sound_log.entry_from(line)
      elsif line.start_with?("frame ") || line == "end"
        moments << [line, [], sounds.size]
      else
        moments.last[1] << line
      end
    end
    moments.map do |heading, rows, sound_count|
      Snapshot.new(heading: heading, variables: Native::HeadlessRun.variables_in(rows),
                   picture: Native::HeadlessRun.picture_in(rows), sounds: sounds.take(sound_count))
    end
  end
end
