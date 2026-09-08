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
# The spread it found on the first run is the reason it exists. Eight examples came in
# between 0.88 and 1.03 of the console's own reading — the bitmap, draw-it-yourself family
# the weights were measured on. The games that hand work to the console's own hardware were
# nowhere near: a lake whose rippling background reads 25 times its estimate, a piano ten
# times, a scrolling background five. Same model, same weights, one family right and another
# wrong. Nothing in a single-game reading could have shown that.
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
  # The estimate is the EVERY-FRAME figure priced with the build's own answers, which is the
  # one the report's budget line judges and the only one the console's reading can be held
  # against. A worst-case total would be a different frame from the one being measured.
  def read_one(name)
    game = load_game(name)
    rom = game.build_rom(err: StringIO.new, out: StringIO.new)
    program = rom.source_program
    model = rom.cost_model
    return Reading.new(name: name, note: "no game loop, so nothing recurs") unless model.looping?(program)

    estimate = model.steady_cost(program).to_f
    Reading.new(name: name, estimate: estimate, **console(game))
  rescue StandardError, ScriptError => e
    Reading.new(name: name, note: "#{e.class}: #{e.message.lines.first.to_s.strip}")
  end

  # The console's own reading of the worst scene. A run that overran a frame reports what a
  # whole pass cost instead, since its scanline reading is pinned at the ceiling and says
  # only "at least a frame".
  def console(game)
    reading = RubyGBA::Analyzer.profile(game).values.max_by(&:scanlines)
    return { note: "the emulator gave no reading" } unless reading
    return { measured: reading.scanlines.to_f } unless reading.saturated?
    return { note: "over a frame, and the pass was not counted" } unless reading.per_pass

    { measured: reading.per_pass.to_f }
  end

  def current(only = nil)
    examples(only).map { |name| read_one(name) }
  end
end

require_relative "cost_accuracy_baseline"
