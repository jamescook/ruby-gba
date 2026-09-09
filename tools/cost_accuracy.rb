# frozen_string_literal: true

require "json"
require "stringio"

# How close the estimate is to the console, for every example at once.
#
#   rake cost:record   measure the corpus and write tools/cost_accuracy_baseline.json
#   rake cost:check    measure it again and fail if any example drifted further off
#
# WHY A CORPUS AND NOT A GAME. One game cannot tell you the estimate is right; it can only
# tell you it is not wrong on that game. Tuned against one program, a weight gets fitted to
# that program's shape, and the next game of a different shape reads badly in a new way —
# which is how a cost model becomes an endless series of local fixes. This measures every
# example in one go, so a change that improves one and quietly worsens six is a failure
# instead of a success story.
#
# HOW TO READ A SPREAD, which is what a corpus is for. The examples fall into families —
# games that draw their own pixels, games that hand the drawing to the console's hardware,
# games whose frame is one expensive mechanism — and where a family sits tells you what kind
# of mistake you are looking at. A PER-GAME error is a weight. A PER-FAMILY error is a
# mechanism nobody priced. A family out by the same fixed AMOUNT points at something a frame
# pays whatever it does; out by the same FACTOR points at a weight on the work it shares.
# None of those readings is available from one game.
#
# WHAT IT GUARDS is drift, not accuracy. Failing on "the ratio is not 1" would fail forever
# on the day it was written, and a check nobody can make green is a check that gets deleted.
# So it records what each example reads today and fails when one moves FURTHER from the
# console. Improvement is never a failure; it prints, and re-recording locks it in — the
# same bargain tools/emitted_baseline.rb makes for code size, and the diff of the recorded
# file is again the thing worth reviewing.
module CostAccuracy
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")
  PATH = File.join(ROOT, "tools", "cost_accuracy_baseline.json")
  VERSION = 1
  ACCEPT = "rake cost:record"

  # How far a ratio may move before it counts as drift. The estimate is deterministic, so
  # its half of the ratio never wobbles; the console's half does, by a fraction of a
  # scanline between runs of the same ROM. A twentieth is far above that and far below any
  # change that matters.
  TOLERANCE = 0.05

  # One example, both ways. +note+ is set instead of a ratio when there is nothing to
  # compare — a program with no game loop has no per-frame cost, and a reading that hit the
  # ceiling is not a frame cost either.
  Reading = Data.define(:name, :estimate, :measured, :note) do
    def initialize(name:, estimate: nil, measured: nil, note: nil)
      super
    end

    def scorable? = note.nil? && estimate.to_f.positive? && measured.to_f.positive?

    # measured / estimate: above 1 the estimate is too cheap, below 1 too dear.
    def ratio = scorable? ? measured / estimate : nil

    # How far off it is, in the same direction whichever way it is wrong — so "worse" can
    # be compared without caring which side of the console the estimate fell.
    def distance
      r = ratio or return nil

      r >= 1 ? r : 1 / r
    end
  end

  module_function

  # Every example that declares a game, by name. Sorted so a recorded file's diff is stable.
  def examples(only = nil)
    wanted = only.to_s.split(",").map { |name| name.strip.sub(/\.rb\z/, "") }.reject(&:empty?)
    names = Dir[File.join(EXAMPLES, "*.rb")].sort
                                            .select { |path| File.read(path).include?("RubyGBA.game") }
                                            .map { |path| File.basename(path, ".rb") }
    wanted.empty? ? names : names.select { |name| wanted.include?(name) }
  end

  # Load one example and hand back the game it declared. Examples print as they build, and
  # that output would land in the middle of this tool's own; give it somewhere else to go.
  def load_game(name)
    known = RubyGBA.registered_games.size
    was = $stdout
    $stdout = StringIO.new
    load File.join(EXAMPLES, "#{name}.rb")
    RubyGBA.registered_games[known..].last
  ensure
    $stdout = was
  end

  # What one example costs, estimated and measured.
  #
  # THE EVERY-FRAME FIGURE AGAINST A TYPICAL FRAME, which is one question asked once. It used
  # to be the every-frame figure against the WORST frame the profiler found, and those are two
  # questions: the model deliberately leaves rare work out of what every frame pays, so a game
  # holding any measured pacman at 1.60 of the console when a typical pacman frame costs 2.48
  # against an estimate of 2.575 — four per cent over. The dear frames were two in a hundred
  # and fifty, and the ratio was measuring how spiky the game is.
  #
  # Eight of the twenty-four scorable examples hold work the every-frame figure leaves out, so
  # this was a third of the corpus scoring the mismatch rather than the model. It flattered as
  # well as penalised: breakout read 0.88 against a worst scene where a typical frame of the
  # same scene is far cheaper.
  #
  # BOTH HALVES OF IT. The walk over the program's statements is only part of a frame: the
  # sound mixer, a background bent row by row, a timer's tick handlers and the sprites a
  # placed fade holds itself off are real per-frame work with no statement to hang on, so the
  # model prices them for the whole frame and the report adds them in. A game whose frame IS
  # one of those — a bent background, a software mixer — is almost entirely standing cost, so
  # the walk alone would read it at a fraction of its own estimate.
  def read_one(name)
    game = load_game(name)
    rom = game.build_rom(err: StringIO.new, out: StringIO.new)
    program = rom.source_program
    model = rom.cost_model
    return Reading.new(name: name, note: "no game loop, so nothing recurs") unless model.looping?(program)

    estimate = (model.steady_cost(program) + model.standing_costs(program)).to_f
    Reading.new(name: name, estimate: estimate, **console(rom))
  rescue StandardError, ScriptError => e
    Reading.new(name: name, note: "#{e.class}: #{e.message.lines.first.to_s.strip}")
  end

  # A TYPICAL FRAME OF THE WORST SCENE. Which scene is still chosen by its worst frame — that
  # is the scene an author cares about and the one the report names — and what is read off it
  # is the middle of its window rather than the peak, so the number means the same thing the
  # every-frame estimate does.
  #
  # A run that overran a frame reports what a whole PASS cost instead, since its scanline
  # reading is pinned at the ceiling and says only "at least a frame". There is no typical
  # frame to be had there: every frame in the window is the ceiling.
  def console(rom)
    readings = RubyGBA::Analyzer.profile(rom.source_program, options: rom.build_options)
    reading = readings.values.max_by(&:scanlines)
    return { note: "the emulator gave no reading" } unless reading
    return { measured: (reading.typical || reading.scanlines).to_f } unless reading.saturated?
    return { note: "over a frame, and the pass was not counted" } unless reading.per_pass

    { measured: reading.per_pass.to_f }
  end

  def current(only = nil)
    examples(only).map { |name| read_one(name) }
  end
end

require_relative "cost_accuracy_baseline"
