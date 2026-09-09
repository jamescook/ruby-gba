# frozen_string_literal: true

require "stringio"

# Which parts of the cost model has anything ever run through?
#
#   rake cost:regimes
#
# WHY THIS IS THE ANTI-OVERFITTING REPORT rather than a tidiness one. A weight that no
# program exercises has never been wrong, because nothing has ever asked it. It is not
# "fine", it is untested — and the first game that reaches it reads as a fresh mystery. The
# difference between a model that is right generically and one that is right about the games
# we happen to have is mostly which regimes those games cover.
#
# A REGIME IS A WEIGHT, which is what makes this computable instead of a matter of judgement.
# The model prices an operation differently depending on context — a divide by a power of two,
# by a fixed number, or by something the game works out; a loop whose counter stays in
# registers or goes through memory; a tear-free screen or a direct-colour one — and every one
# of those contexts is a separate weight. So "which regimes does the corpus reach" is "which
# weights does the corpus read", and nothing has to be enumerated by hand. A regime added
# tomorrow appears here on its own.
#
# HOW IT IS MEASURED: make one weight cost a scanline more and price the corpus again. What
# the frames gain is HOW MANY TIMES they pay it — exactly, for a cost built by adding weights
# up, which is nearly all of this model. Times the weight's own value, that is the frame time
# it carries.
#
# A scanline MORE rather than nothing at all, and the difference matters at both ends. Taking
# a weight away cannot tell "nothing asks for this" from "everything asks for it and it was
# measured at nothing" — var_operand is the second, and reads as a blind spot under the other
# method. Adding to it separates them: a count with no time behind it is a regime the corpus
# exercises heavily and which happens to be free.
#
# Where a weight is used some other way than by adding it up — a divisor, a rate that decides
# how many interrupts arrive — the number is not a count. It is still the answer to "what
# changes if this is wrong", which is the question being asked, and #counts? says which kind
# of answer you are reading.
#
# IT ALSO ANSWERS THE OPPOSITE, and that is worth as much: which regimes carry real frame
# time. A weight the corpus leans on is where accuracy actually matters, and one that carries
# a rounding error does not deserve another afternoon however wrong its ratio looks.
module CostRegimes
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")

  # A weight and what the corpus does with it. +times+ is how many times the corpus's frames
  # pay it, added up; +carried+ is what that comes to in frame time; +programs+ is how many
  # programs pay it at all.
  Regime = Data.define(:weight, :value, :times, :programs, :note) do
    def exercised? = programs.positive?

    # Read by the corpus and worth nothing when it is — a regime that IS exercised and simply
    # costs nothing, which is a different thing from one nothing reaches.
    def free? = exercised? && value.zero?

    def carried = times * value
  end

  # The weights that are not a count of anything: a factor the model divides by, and a rate
  # that decides how many interrupts a frame answers. Perturbing these says what changes if
  # they are wrong, which is still worth knowing, but the number is not "times a frame".
  NOT_COUNTS = %i[fast_code_speedup].freeze

  # How much to add to a weight to see what depends on it. One scanline is large next to every
  # weight in the table, so the difference is well clear of anything a float loses.
  NUDGE = 1.0

  module_function

  # The examples — the same corpus the accuracy baseline scores. Games under games/ are their
  # own projects with their own suites, and the framework's tooling does not reach into them.
  # Built once — the pricing below is asked of each of them dozens of times.
  def corpus
    names = Dir[File.join(EXAMPLES, "*.rb")].sort
                                            .select { |path| File.read(path).include?("RubyGBA.game") }
    names.filter_map { |path| load_program(File.basename(path, ".rb")) { load path } }
  end

  # Load one file and hand back [name, program, the build's own answers]. A program is priced
  # with the facts of its own build — which routines went to the quick memory, where the
  # variables landed — because an estimate without them reads nearly threefold wrong.
  def load_program(name)
    known = RubyGBA.registered_games.size
    was = $stdout
    $stdout = StringIO.new
    yield
    game = RubyGBA.registered_games[known..].last or return nil
    rom = game.build_rom(err: StringIO.new, out: StringIO.new)
    [name, rom.source_program, rom.built.for_cost_model]
  rescue StandardError, ScriptError => e
    warn "#{name}: #{e.class}: #{e.message.lines.first.to_s.strip}"
    nil
  ensure
    $stdout = was
  end

  # The worst frame a program can reach, priced with +overrides+ on top of the build's facts.
  # The WORST rather than the every-frame figure, because the question is whether anything in
  # the corpus reaches this code path at all — a body behind a rare test still exercises the
  # weights it holds.
  def frame(program, facts, **overrides)
    model = RubyGBA::IR::CostModel.new(**facts, **overrides)
    (model.frame_cost(program) + model.standing_costs(program)).to_f
  rescue StandardError
    Float::NAN
  end

  # What the corpus does with every weight. One pricing per program to start from, then one
  # more per weight per program.
  def measure(corpus = self.corpus)
    weights = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
    base = corpus.to_h { |name, program, facts| [name, frame(program, facts)] }
    weights.map do |weight, value|
      times = 0.0
      programs = 0
      corpus.each do |name, program, facts|
        moved = (frame(program, facts, weight => value + NUDGE) - base[name]) / NUDGE
        next unless moved.finite? && moved.abs > 1e-6

        times += moved
        programs += 1
      end
      Regime.new(weight: weight, value: value, times: times, programs: programs,
                 note: note_for(weight))
    end
  end

  def counts?(weight) = !NOT_COUNTS.include?(weight)

  def note_for(weight)
    RubyGBA::IR::CostModel::WEIGHT_DOMAINS.dig(weight, :note) || ""
  end

  # How many programs a regime has to reach before one of them being wrong would show up
  # anywhere else. At one, the corpus has a single witness and no second opinion.
  LONELY = 1

  # ...and how much of the corpus a lonely regime has to carry before that is worth acting on.
  # Plenty of weights are reached by one program and carry a rounding error; the ones that
  # matter are where a single witness is holding up a real share of the answer.
  WORTH_A_SECOND_WITNESS = 0.01

  def report(regimes, out: $stdout, top: 15)
    reached = regimes.select(&:exercised?)
    total = reached.sum(&:carried)
    heaviest_lines(reached, total, out, top)
    blind_lines(regimes.reject(&:exercised?), out)
    lonely_lines(reached, total, out)
    free_lines(reached.select(&:free?), out)
    out.puts
    out.puts "#{reached.length} of #{regimes.length} regimes are exercised by the corpus."
  end

  # WHERE ACCURACY ACTUALLY MATTERS. A weight the corpus leans on is worth an afternoon; one
  # carrying a rounding error is not, however wrong its ratio looks.
  def heaviest_lines(reached, total, out, top)
    out.puts "what the corpus leans on:"
    out.puts format("  %-30s %10s %8s %6s  %s", "regime", "carried", "times", "progs", "share")
    reached.sort_by { |r| -r.carried }.first(top).each do |r|
      out.puts format("  %-30s %10.1f %8s %6d  %5.1f%%", r.weight, r.carried,
                      counts?(r.weight) ? r.times.round : "-", r.programs,
                      total.positive? ? r.carried / total * 100 : 0)
    end
  end

  # THE POINT OF THE WHOLE REPORT. Nothing has ever asked these, so nothing has ever found
  # them wrong, and the first game that reaches one reads as a fresh mystery.
  def blind_lines(blind, out)
    out.puts
    return out.puts "no blind spots: every regime is exercised somewhere." if blind.empty?

    out.puts "NEVER EXERCISED — nothing in the corpus asks these, so nothing has found them wrong:"
    blind.sort_by(&:weight).each { |r| out.puts format("  %-30s %s", r.weight, r.note) }
  end

  # ...and the near-miss: reached, but by one program only. If that weight is wrong, one
  # reading is wrong and nothing else in the corpus disagrees with it.
  def lonely_lines(reached, total, out)
    lonely = reached.select { |r| r.programs <= LONELY }.sort_by { |r| -r.carried }
    share = ->(r) { total.positive? ? r.carried / total : 0 }
    worth, slight = lonely.partition { |r| share.call(r) >= WORTH_A_SECOND_WITNESS }
    return if lonely.empty?

    out.puts
    out.puts "ONE WITNESS ONLY — exercised, but by a single program, so nothing checks it:"
    worth.each do |r|
      out.puts format("  %-30s %5.1f%% of the corpus  %s", r.weight, share.call(r) * 100, r.note)
    end
    return if slight.empty?

    out.puts "  ...and #{slight.length} more carrying almost none of the corpus between them " \
             "(#{slight.map(&:weight).sort.join(', ')})"
  end

  # Exercised and free. Worth naming so a reader does not mistake it for a blind spot.
  def free_lines(free, out)
    return if free.empty?

    out.puts
    out.puts "EXERCISED AND MEASURED AT NOTHING — read often, costs nothing:"
    free.sort_by(&:weight).each { |r| out.puts format("  %-30s %s", r.weight, r.note) }
  end
end
