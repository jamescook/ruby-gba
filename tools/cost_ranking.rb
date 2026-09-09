# frozen_string_literal: true

require "stringio"

# Does the report point at the right line? Scored by taking a line away and measuring.
#
#   rake cost:ranking              every example that fits in a frame
#   rake cost:ranking ONLY=snake   one of them, while working on it
#
# THE OTHER HALF OF SCORING THE MODEL. `rake cost:check` scores the TOTAL — how close the
# estimate is to the console for a whole frame. A total says nothing about whether the report
# points at the right line inside it, and the line is what a reader acts on: an estimate that
# is exact in total and has two lines the wrong way round sends somebody to optimise the
# wrong thing, and no whole-frame check can tell.
#
# THERE IS NO PER-LINE GROUND TRUTH TO COMPARE AGAINST. The emulator gives a frame cost, not
# a cost per statement. The only way to get one is to take a line away and measure again: what
# the frame got cheaper by is what that line really cost. That habit has found real errors
# twice by hand, and this is it made mechanical. For each example the top few lines of the
# report's own ranking are each removed in turn, the variant is built and measured, and the
# model is scored by how well the order of its predicted savings matches the order of the
# measured ones. A model that ranks the frame correctly predicts which deletion saves the most.
#
# WHICH FIGURE IS BEING DIFFERENCED, said on every line because it changes what the number
# means. A game that fits in a frame is measured in scanlines, and a delta is a delta. A game
# that overruns measures in whole passes — its per-frame reading sits at the ceiling however
# far over it is — so 2.00 against 2.10 is a cliff and not a five percent difference, and only
# the per-PASS figure resolves anything there. The report says "per frame" or "per pass".
#
# A DELTA SMALLER THAN THE NOISE RANKS NOTHING. Two runs of the same ROM differ by a fraction
# of a scanline, so two lines whose measured savings are a tenth apart are not in an order at
# all, and counting them as one would be counting noise. Lines under the floor are shown and
# left out of the score.
#
# WHICH LINES ARE TRIED. The console's reading is the every-frame figure, so the order being
# checked is the estimate's order on THAT figure — and the every-frame walk has no per-line
# breakdown of its own; the tree prices the worst frame. So the tree nominates candidates, its
# heaviest lines, and each candidate is priced by taking it away and asking the every-frame
# figure what it saved. The lines that save the most on paper are the ones measured. A line
# the worst frame leans on and a normal frame never reaches saves nothing on paper, and is
# not worth an emulator run to find out it saves nothing on the console either.
module CostRanking
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")

  # How many lines to take away and measure, per example. Each one is a build and an emulator
  # run, so this is the knob on how long the whole thing takes.
  TOP = 5

  # How many of the tree's heaviest lines to price before choosing the TOP to measure. Pricing
  # is a lowering with no emulator, so it is cheap next to a measurement.
  CANDIDATES = 12

  # The measurement's own wobble, in scanlines: the same floor the profiler uses before it
  # blames a held button for a dearer frame. A measured saving under it is not a saving.
  NOISE = RubyGBA::Analyzer::WORTH_BLAMING

  # One line taken away: what the estimate said the frame would save, and what it did save.
  Ablation = Data.define(:line, :estimated, :measured, :note) do
    def initialize(line:, estimated: nil, measured: nil, note: nil)
      super
    end

    def readable? = note.nil? && !measured.nil?
    def rankable? = readable? && measured.abs >= NOISE
  end

  # One example's score. +figure+ is :frame or :pass — which reading the deltas are of.
  Score = Data.define(:name, :figure, :ablations, :note) do
    def initialize(name:, figure: nil, ablations: [], note: nil)
      super
    end

    def scorable? = note.nil? && rankable.length >= 2
    def rankable = ablations.select(&:rankable?)

    # Does the estimate's dearest line save the most on the console? The question a reader
    # asks first, and the one a wrong order costs the most on.
    def top_agrees?
      return nil unless scorable?

      rankable.max_by(&:estimated).line == rankable.max_by(&:measured).line
    end

    # How much of the estimate's ORDER the console agrees with: of every pair of lines, the
    # share the two put in the same order, less the share they put in opposite orders. 1.0
    # is the same order throughout; -1.0 is the reverse; 0 is no relation. (Kendall's tau.)
    def agreement
      return nil unless scorable?

      pairs = rankable.combination(2).to_a
      same = pairs.count { |a, b| (a.estimated <=> b.estimated) == (a.measured <=> b.measured) }
      opposite = pairs.count { |a, b| (a.estimated <=> b.estimated) == -(a.measured <=> b.measured) && a.measured != b.measured }
      (same - opposite).to_f / pairs.length
    end
  end

  module_function

  def examples(only = nil)
    wanted = only.to_s.split(",").map { |name| name.strip.sub(/\.rb\z/, "") }.reject(&:empty?)
    names = Dir[File.join(EXAMPLES, "*.rb")].sort
                                            .select { |path| File.read(path).include?("RubyGBA.game") }
                                            .map { |path| File.basename(path, ".rb") }
    wanted.empty? ? names : names.select { |name| wanted.include?(name) }
  end

  def load_game(name)
    known = RubyGBA.registered_games.size
    was = $stdout
    $stdout = StringIO.new
    load File.join(EXAMPLES, "#{name}.rb")
    RubyGBA.registered_games[known..].last
  ensure
    $stdout = was
  end

  # Score one example: the report's hottest lines, each taken away and measured.
  def score(name)
    rom = load_game(name).build_rom(err: StringIO.new, out: StringIO.new)
    program = rom.source_program
    options = rom.build_options
    model = rom.cost_model
    return Score.new(name: name, note: "no game loop, so nothing recurs") unless model.looping?(program)

    base = console(program, options)
    return Score.new(name: name, note: base[:note]) if base[:note]

    chosen = chosen_lines(program, options, every_frame(model, program), candidate_lines(model, program))
    return Score.new(name: name, note: "no line saves anything on paper, so there is no order to check") if chosen.empty?

    ablations = chosen.map { |line, variant, estimated| ablate(variant, options, line, estimated, base) }
    Score.new(name: name, figure: base[:figure], ablations: ablations)
  rescue StandardError, ScriptError => e
    Score.new(name: name, note: "#{e.class}: #{e.message.lines.first.to_s.strip}")
  end

  # The console's reading of the worst scene, and which figure it is. A run that fits is a
  # frame cost; one that overran only means something per pass.
  def console(program, options)
    reading = RubyGBA::Analyzer.profile(program, options: options).values.max_by(&:scanlines)
    return { note: "the emulator gave no reading" } unless reading
    return { measured: reading.scanlines.to_f, figure: :frame } unless reading.saturated?
    return { note: "over a frame, and the pass was not counted" } unless reading.per_pass

    { measured: reading.per_pass.to_f, figure: :pass }
  end

  # The estimate's every-frame figure, which is the one the console's reading is held
  # against (see tools/cost_accuracy.rb).
  def every_frame(model, program)
    (model.steady_cost(program) + model.standing_costs(program)).to_f
  end

  # The tree's heaviest source lines, dearest first: every leaf of the cost tree weighed by
  # how many times a frame reaches it, summed by the line it came from. Left out: leaves the
  # author did not write (the frame's own wait, the sound mixer), which have no line; the
  # game loop's own line, which is the frame and not a line in it; and anything the framework
  # built on the author's behalf, which borrows the line this tool loaded the game from.
  def candidate_lines(model, program, top: CANDIDATES)
    tree = model.category_tree(program)
    skip = program.children.select { |node| node.kind == :loop }.map(&:source)
    RubyGBA::IR::CostModel::Tree.weigh_leaves(tree)
                                .select { |leaf, _times| leaf.source }
                                .reject { |leaf, _times| skip.include?(leaf.source) || leaf.source.start_with?(File.basename(__FILE__)) }
                                .group_by { |leaf, _times| leaf.source }
                                .transform_values { |rows| rows.sum { |leaf, times| leaf.cost * times } }
                                .sort_by { |_line, cost| -cost }
                                .first(top)
                                .map(&:first)
  end

  # Of the candidates, the TOP that save the most on paper: [line, variant, estimated saving]
  # each, dearest first. A line that saves nothing every frame is not tried, and a line whose
  # variant will not build is passed over.
  def chosen_lines(program, options, base_estimate, candidates, top: TOP)
    priced = candidates.filter_map do |line|
      variant = without(program, line) or next
      estimated = base_estimate - every_frame(model_for(variant, options), variant)
      [line, variant, estimated] if estimated.positive?
    rescue StandardError
      nil
    end
    priced.max_by(top) { |_line, _variant, estimated| estimated }
  end

  # Measure what taking one line away really saved, beside what the estimate said it would.
  # Both deltas are BASE minus VARIANT, so a positive number is a saving.
  def ablate(variant, options, line, estimated, base)
    after = console(variant, options)
    return Ablation.new(line: line, estimated: estimated, note: after[:note]) if after[:note]
    if after[:figure] != base[:figure]
      return Ablation.new(line: line, estimated: estimated,
                          note: "taking it away changed which figure the console can give")
    end

    Ablation.new(line: line, estimated: estimated, measured: base[:measured] - after[:measured])
  rescue StandardError => e
    Ablation.new(line: line, note: "#{e.class}: #{e.message.lines.first.to_s.strip}")
  end

  # A copy of +program+ with every statement from +line+ removed — the OUTERMOST ones, so a
  # block written on that line goes with everything inside it, as deleting the line would.
  # nil when no statement carries the line.
  def without(program, line)
    copy = program.copy
    doomed = copy.each.select { |node| node.source == line && node.parent&.source != line }
    return nil if doomed.empty?

    doomed.each { |node| node.parent.children.delete(node) }
    copy
  end

  # A cost model that knows how the VARIANT was built. The same statements can cost a
  # different amount once a line is gone — a routine that did not fit in quick memory may
  # fit now — and the estimate has to be told, exactly as rom.cost_model is.
  def model_for(program, options)
    backend = RubyGBA::IR::Backends::GBA.new(**options)
    backend.lower(program)
    RubyGBA::IR::CostModel.new(**backend.build_record(program).for_cost_model)
  end

  def run(only: nil, out: $stdout)
    scores = examples(only).map do |name|
      out.print "#{name}... "
      out.flush
      score(name).tap { |s| out.puts(s.note || "#{s.ablations.length} lines") }
    end
    out.puts
    report(scores, out: out)
    scores
  end

  def report(scores, out: $stdout)
    scores.each { |score| example_lines(score, out) }
    summary_lines(scores, out)
  end

  def example_lines(score, out)
    out.puts "#{score.name}#{score.figure ? " (per #{score.figure})" : ''}"
    return out.puts "  #{score.note}" if score.note

    out.puts format("  %-28s %10s %10s", "line", "estimated", "measured")
    score.ablations.each do |a|
      out.puts format("  %-28s %10s %10s  %s", a.line, fmt(a.estimated), fmt(a.measured), note_for(a))
    end
    out.puts "  #{verdict_for(score)}"
    out.puts
  end

  def note_for(ablation)
    return ablation.note if ablation.note
    return "under the noise, not ranked" unless ablation.rankable?

    ""
  end

  def verdict_for(score)
    return "fewer than two lines saved more than the noise, so there is no order to score" unless score.scorable?

    top = score.top_agrees? ? "the dearest line is the dearest on the console" : "THE DEAREST LINE IS NOT THE DEAREST ON THE CONSOLE"
    "#{top}; order agreement #{format('%.2f', score.agreement)} over #{score.rankable.length} lines"
  end

  # The corpus at a glance: on how many examples the estimate's dearest line is the console's,
  # which is the number that says whether the report can be trusted to point.
  def summary_lines(scores, out)
    scored = scores.select(&:scorable?)
    return out.puts "No example could be scored." if scored.empty?

    agreed = scored.count(&:top_agrees?)
    mean = scored.sum(&:agreement) / scored.length
    out.puts "The estimate's dearest line is the console's on #{agreed} of #{scored.length} examples " \
             "that could be scored; order agreement averages #{format('%.2f', mean)}."
    wrong = scored.reject(&:top_agrees?).map(&:name)
    out.puts "Pointing at the wrong line: #{wrong.join(', ')}." unless wrong.empty?
  end

  def fmt(value)
    value.nil? ? "-" : format("%.2f", value)
  end
end
