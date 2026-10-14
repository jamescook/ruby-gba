# frozen_string_literal: true

# Runs one program twice — in the interpreter, which is the answer key, and as C built with no
# window — and checks the two agree on every variable, every pixel of the picture shown, every
# entry of the sound log and every sprite drawn, at every frame boundary and at the end.
#
# What is compared is what the windowless runtime prints (rg_headless.c): every variable the
# program names, the picture, which sprites it last drew and where, and the sound log as it
# grows, at the start of each frame and when the run stops. The interpreter's answer is read at
# the same moments (each_vblank, and after run), and a variable it never wrote reads 0, which is
# also what the C starts every variable at. Playing the two and saying how they differ is the
# library's (Native::Differences); this is the suite's assertions over it.
module NativeComparison
  include RubyGBA::IR::Backends::Native::Differences

  Native = RubyGBA::IR::Backends::Native
  Reference = RubyGBA::IR::Backends::Reference
  Builder = RubyGBA::Builder
  WIDTH = RubyGBA::IR::Screen::WIDTH

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

  # +program+ with runs of its frame's sprites drawn in the order a list holds, written onto the
  # statement that draws them. The builder writes a run only beside the routine that keeps its
  # list in order, so a test of what the list may hold writes the run itself. The block is handed
  # the names the frame draws, and gives back each run as [the names in it, its list].
  def with_draw_orders_written_by_hand(program)
    program.walk.select { |node| node.kind == :present_objects }.each do |drawn|
      runs = yield(drawn.names).map { |names, list| RubyGBA::IR::Build::DrawOrder.new(objects: names, order: list) }
      ordered = RubyGBA::IR::Build.present_objects(drawn.names, orders: runs)
      beside = drawn.parent.children
      beside[beside.index(drawn)] = ordered
      ordered.parent = drawn.parent
    end
    program
  end

  # +buttons+ maps a frame number (from 1) to the buttons held during it. Gives back the
  # interpreter's last snapshot, so a test can also say the run did something worth comparing —
  # two runs that both left everything at 0 agree too.
  #
  # +played+ is the interpreter's snapshots of this same run, for a test that has already played
  # it to read them: a long run of a game the interpreter is slow at is then played once.
  def assert_native_matches_reference(program, frames: 5, buttons: {}, played: nil)
    expected = played || reference_snapshots(program, frames: frames, buttons: buttons)
    %i[checked fast].each do |mode|
      actual = native_snapshots(program, frames: frames, buttons: buttons, mode: mode)
      assert_equal expected.map(&:heading), actual.map(&:heading), "the frame boundaries differ (#{mode} build)"
      expected.zip(actual).each { |want, got| assert_same_moment(want, got, mode) }
    end
    expected.last
  end

  # A recorded run of +buttons+: the two agree on every frame of it, and the buttons did
  # something — the picture the run ends on is not the one the game ends on when it is left
  # alone. Without that second half a run whose buttons never reach the game compares two games
  # standing still, and passes. It says the run moved, not that every leg of it did: the comment
  # on the buttons is where that is worked out.
  def assert_recorded_run_matches_reference(program, frames:, buttons:)
    last = assert_native_matches_reference(program, frames: frames, buttons: buttons)
    untouched = reference_snapshots(program, frames: frames, buttons: {}).last
    assert untouched.picture != last.picture, "the buttons should have changed the picture the run ends on"
    last
  end

  # How many different pictures the interpreter shows over a run with nothing held: what a test
  # of a game that moves by itself says "it moved" with.
  def different_pictures_in(program, frames:)
    reference_snapshots(program, frames: frames, buttons: {}).map(&:picture).uniq.length
  end

  private

  # Everything that differs at one moment, said together: a wrong variable usually explains a
  # wrong picture, and seeing both at once says which.
  def assert_same_moment(want, got, mode)
    differences = variable_differences(want.variables, got.variables) +
                  [picture_difference(want.picture, got.picture), sounds_difference(want.sounds, got.sounds),
                   sprites_difference(want.sprites, got.sprites)].compact
    assert_empty differences, "at #{got.heading} (#{mode} build)"
  end
end
