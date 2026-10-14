# frozen_string_literal: true

require "native_comparison"

# What `game_player` hands a test on a native run: the game played as C (Native::HeadlessRun),
# and then the same buttons, frame for frame, played on the interpreter — with the run failing at
# the first frame the two disagree on, about any variable, any list or pool, any pixel, which
# sprites were drawn and where, or which recordings the mixer is sounding — and at the end, about
# every slice of mixed sound and how many sounds a full mixer lost. A game that saves is played both ways from the same save memory, and the two have to
# end the run with the same bytes in it.
#
# A test that watches the run (each_vblank) watches the game as C, as it goes; the interpreter
# is played afterwards, and nothing is watched twice.
#
# That is what makes opting a file into native runs worth more than its own checks. Those look at
# the pixels and variables whoever wrote them thought to look at; this looks at everything, at
# every frame, so a native lowering that draws something wrong where no test was looking still
# fails. The buttons are the ones the native run was actually given, so an input script that
# decided from what the game was doing is replayed exactly, without being asked again. (A run by
# step budget does ask the script once more, beforehand: see #frames_within.)
#
# Pictures are compared by a check number for each frame (see HeadlessRun::Moment), which is
# what keeps a long run cheap; only a run that fails is played again in full, to say where.
class CheckedNativeRun
  include NativeComparison
  extend NativeComparison

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun
  SaveImage = RubyGBA::IR::SaveImage
  Moment = HeadlessRun::Moment

  # Every frame's buttons reach the native run through one script, which keeps them for the
  # replay: the test's own script when it gave one, else whatever it held for the whole run.
  # +save+ is the save memory the game starts with, as the interpreter takes it, and it holds
  # what the game as C left in it once the run is over.
  def initialize(save: SaveImage.new)
    @save = save
    @native = HeadlessRun.new(save: save)
    @played = {}
    @held = []
    @native.input_each_frame { |frame| @played[frame] = buttons_for(frame) }
  end

  def hold(*buttons)
    @held = buttons
    self
  end

  def input_each_frame(&script)
    @script = script
    self
  end

  # The native run does the watching, so the block reads the game as C at each frame boundary.
  # This is what comes back, and not the native run: the run a test goes on to make from here
  # has to be the checked one.
  def each_vblank(&block)
    @native.each_vblank(&block)
    self
  end

  # +frames+ as the interpreter counts them. A step budget alone (+max_steps+) is the
  # interpreter's own measure, and the C keeps no count of its steps — so the interpreter says
  # how many frames fit in the budget, and the C plays that many. Beside +frames+ a budget only
  # guards one frame of the interpreter, and means nothing here.
  def run(program, max_steps: nil, frames: nil)
    frames ||= max_steps ? frames_within(program, max_steps) : Reference::DEFAULT_FRAMES
    interpreters_save = save_as_handed_over
    @native.run(program, frames: frames)
    interpreter, moments = play_on_interpreter(program, frames, interpreters_save)
    difference = self.class.first_difference(moments, @native.moments) ||
                 self.class.sounds_difference(interpreter.audio, @native.audio_played) ||
                 self.class.mix_difference(interpreter.mixed_sound, @native.mixed_sound) ||
                 self.class.drops_difference(interpreter.sound_drops, @native.sound_drops) ||
                 self.class.save_difference(interpreters_save, @save)
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
      if reference.sounds != native.sounds
        differences << "the sound log holds #{native.sounds} entries in the C and #{reference.sounds} in Reference"
      end
      differences.concat([sprites_difference(reference.sprites, native.sprites)].compact)
      differences.concat(collections_differences(reference.collections, native.collections))
      if reference.sounding != native.sounding
        differences << "the mixer sounds #{native.sounding.inspect} in the C and #{reference.sounding.inspect} in Reference"
      end
      return "#{heading(reference.frame)}: #{differences.join('; ')}" if differences.any?
    end
    nil
  end

  # Each list and each pool field +got+ (the C) holds differently from +want+ (the interpreter),
  # said with both.
  def self.collections_differences(want, got)
    lists = (want[:lists].keys | got[:lists].keys).filter_map do |name|
      mine, theirs = got[:lists][name], want[:lists][name]
      "list :#{name}: C has #{mine.inspect}, Reference #{theirs.inspect}" if mine != theirs
    end
    fields = (want[:pools].keys | got[:pools].keys).flat_map do |pool|
      mine, theirs = got[:pools].fetch(pool, {}), want[:pools].fetch(pool, {})
      (theirs.keys | mine.keys).filter_map do |field|
        next if mine[field] == theirs[field]

        "pool :#{pool} field :#{field}: C has #{mine[field].inspect}, Reference #{theirs[field].inspect}"
      end
    end
    lists + fields
  end

  def self.heading(frame) = frame == :end ? "the end of the run" : "frame #{frame}"
  def self.last_frame(moments) = moments.map(&:frame).grep(Integer).max || 0

  private

  # How many frames the interpreter plays in +max_steps+ steps: it stops a game on the frame
  # boundary after the budget runs out, so a run by budget is a run of that many whole frames.
  # The buttons are asked of the test's own script here and again on the native run, so a script
  # that reads the game sees it as it stood before this run.
  def frames_within(program, max_steps)
    lead = Reference.new(save: save_as_handed_over).input_each_frame { |frame| buttons_for(frame) }
                    .run(program, max_steps: max_steps)
    return lead.frame unless lead.frame.zero? && lead.stopped_at_budget?

    raise HeadlessRun::CannotAnswer, "this game spends the whole step budget before it first waits for the " \
                                     "screen, so the budget is all that stops it, and the native lowering " \
                                     "keeps no count of its steps"
  end

  def buttons_for(frame) = @script ? Array(@script.call(frame)) : @held

  # A save memory of the interpreter's own holding what this run's holds now, and cut at the same
  # step where a cut is waiting — taken before the game as C plays, which leaves its own bytes in
  # the one the test handed over.
  def save_as_handed_over
    copy = @save.dup
    copy.cut_power_after(@save.power_left) if @save.power_left
    copy
  end

  # The interpreter played on the same buttons from +save+, and its moments.
  def play_on_interpreter(program, frames, save)
    interpreter = Reference.new(save: save)
    moments = []
    interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
               .each_vblank { |frame| moments << moment_of(interpreter, frame) }
               .run(program, frames: frames)
    [interpreter, moments << moment_of(interpreter, :end)]
  end

  def moment_of(interpreter, frame)
    Moment.new(frame: frame, variables: interpreter.vars.dup, picture: HeadlessRun.picture_check(interpreter.screen.shown),
               sounds: interpreter.audio.size, sprites: interpreter.sprites,
               collections: interpreter.game_state.except(:vars), sounding: interpreter.active_samples)
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
