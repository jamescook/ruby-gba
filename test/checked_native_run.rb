# frozen_string_literal: true

require "zlib"
require "native_comparison"

# What `game_player` hands a test on a native run: the game played as C (Native::HeadlessRun),
# and then the same buttons, frame for frame, played on the interpreter — with the run failing at
# the first frame the two disagree on, about any variable or any pixel.
#
# That is what makes opting a file into native runs worth more than its own checks. Those look at
# the pixels and variables whoever wrote them thought to look at; this looks at everything, at
# every frame, so a native lowering that draws something wrong where no test was looking still
# fails. The buttons are the ones the native run was actually given, so an input script that
# decided from what the game was doing is replayed exactly, without being asked again.
#
# Pictures are compared by a check number for each frame (see HeadlessRun::Moment), which is
# what keeps a long run cheap; only a run that fails is played again in full, to say where.
class CheckedNativeRun
  include NativeComparison
  extend NativeComparison

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun
  Moment = HeadlessRun::Moment

  def initialize(save: nil)
    @native = HeadlessRun.new(save: save)
    @played = {}
  end

  def input_each_frame(&script)
    @native.input_each_frame { |frame| @played[frame] = Array(script.call(frame)) }
    self
  end

  def run(program, frames: Reference::DEFAULT_FRAMES)
    @native.run(program, frames: frames)
    difference = self.class.first_difference(interpreter_moments(program, frames), @native.moments)
    raise Minitest::Assertion, disagreement_message(difference, program, frames) if difference

    self
  end

  def [](name) = @native[name]
  def screen = @native.screen

  # Everything else is the native run's to answer, or to say it cannot yet.
  def method_missing(name, ...) = @native.public_send(name, ...)
  def respond_to_missing?(name, include_private = false) = @native.respond_to?(name, include_private)

  # The first moment +got+ (the C) disagrees with +want+ (the interpreter) on, said as the frame
  # and everything that differs there; nil when they agree throughout.
  def self.first_difference(want, got)
    if want.map(&:frame) != got.map(&:frame)
      return "how far the run went: the interpreter stopped after frame #{last_frame(want)}, " \
             "the C after frame #{last_frame(got)}"
    end

    want.zip(got).each do |reference, native|
      differences = variable_differences(reference.variables, native.variables)
      differences << "the picture differs" if reference.picture != native.picture
      return "#{heading(reference.frame)}: #{differences.join('; ')}" if differences.any?
    end
    nil
  end

  def self.heading(frame) = frame == :end ? "the end of the run" : "frame #{frame}"
  def self.last_frame(moments) = moments.map(&:frame).grep(Integer).max || 0

  private

  def interpreter_moments(program, frames)
    interpreter = Reference.new
    moments = []
    interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
               .each_vblank { |frame| moments << moment_of(interpreter, frame) }
               .run(program, frames: frames)
    moments << moment_of(interpreter, :end)
  end

  def moment_of(interpreter, frame)
    Moment.new(frame: frame, variables: interpreter.vars.dup,
               picture: Zlib.crc32(interpreter.screen.shown.pack("v*")))
  end

  # A picture that differs is played again with every pixel of every frame, to say where.
  def disagreement_message(difference, program, frames)
    message = "the native lowering and the interpreter disagree at #{difference}"
    return message unless difference.include?("picture")

    want = reference_snapshots(program, frames: frames, buttons: @played)
    got = native_snapshots(program, frames: frames, buttons: @played, mode: :checked)
    first = want.zip(got).find { |reference, native| reference.picture != native.picture }
    first ? "#{message} (#{first.last.heading}: #{picture_difference(first.first.picture, first.last.picture)})" : message
  end
end
