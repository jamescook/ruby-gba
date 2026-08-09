# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE KEEP-HONEST CHECK: the cost model's weights were measured on the emulator's GBA
# timing model, and this is what makes sure they stay true.
#
# The failure this exists for is a quiet one. `rom.explain` puts an ESTIMATED breakdown
# next to a MEASURED total and, until recently, never related the two — so when a cost
# was missing from the model entirely, both halves still looked fine. The tree summed to
# something plausible. The verdict read correct, because it was measured. Nothing anywhere
# looked odd. A timer's tick handler cost nothing for as long as it did for exactly that
# reason: the estimate said 0, the emulator said 9 scanlines, and the two sat four lines
# apart in the same report with nobody to notice.
#
# So each case here is a PAIR of programs that differ in exactly one thing, and the
# measurement is the difference between them. That is the whole trick, and it is why the
# emulator does not have to attribute anything to anything: it reads two whole frames, and
# everything the two programs share — the boot, the wait for the screen, the loop — cancels.
# What is left is the one cost, measured, against what the model predicts for it alone.
#
# WELL INSIDE A FRAME, DELIBERATELY. The reading cannot count past a frame's worth of work,
# so a fixture that filled a frame would saturate near 228 and a real divergence would read
# as agreement — the most dangerous shape a test can have. #test_the_readings_stay_well_
# inside_a_frame holds every fixture to a fraction of a frame so that cannot happen.
class TestCostCalibration < Minitest::Test

  CostModel = RubyGBA::IR::CostModel

  # A standing cost in a form a machine can check: two programs that differ in exactly one
  # thing (+shape+, given `with` true and false), what the model says that thing costs
  # (+predict+), and the single weight the answer turns on (+weight+).
  #
  # +fast_code+ picks which memory the code under test runs from, because for an interrupt
  # that is not a detail — it is a different measured weight. A shipping game keeps its
  # interrupt handler in the console's quick memory and pays bend_line_fast; a game whose
  # routines did not fit pays bend_line. Both are calibrated, so both are checked.
  Standing = Data.define(:name, :weight, :fast_code, :shape, :predict)

  # How far a prediction may sit from its measurement before this fails: a quarter, plus a
  # scanline of slack for the small fixed costs that survive the differencing. Generous on
  # purpose — the model is a deliberate approximation and this guards against real drift,
  # not noise.
  BAND = 0.25
  SLACK = 1.0

  # A drifted weight has to move its own prediction clear out of the band. Three times is
  # far more than any real drift and keeps the check about wiring, not sensitivity.
  DRIFT = 3

  # No fixture may cost more than this share of a frame, or the reading saturates.
  ROOM_IN_A_FRAME = 0.5

  MIXER_VOICES = CostModel::MIXER_VOICES
  TICK_HZ = 4000
  WAVE_ROWS = 64

  # The software mixer, which sums every sounding voice into the output buffer once a
  # frame. Priced at its full voice count, so the fixture sounds them all — a fixture
  # playing one sample would measure an eighth of what the model quotes and read as drift.
  MIXER = lambda do |with|
    screen :bitmap
    clear_screen :black
    if with
      MIXER_VOICES.times do |i|
        sample(:"v#{i}", pcm: [30, -30] * 400, rate: CostModel::DEFAULT_MIXER_RATE).play(loop: true)
      end
    end
    game_loop { }
  end

  # Bending a background row by row: the display interrupts the program after every line it
  # counts, and the block works out that row's offset. Neither is a statement anybody wrote
  # in the frame, which is why it has to be measured whole rather than found in the op tree.
  BEND = lambda do |with|
    screen :tiled
    image(:sky, "." => :blue) { ("." * 8 + "\n") * 8 }
    tiles :set, "." => :sky
    water = background :water, tiles: :set, map: Array.new(20) { "." * 30 }
    ripple = table :ripple, (0...WAVE_ROWS).map { |i| (Math.sin(i * 2 * Math::PI / WAVE_ROWS) * 4).round }
    phase = var :phase, 0
    water.scroll_each_row { |row| ripple[(row - phase) % WAVE_ROWS] } if with
    game_loop { phase.add 1 }
  end

  # A timer's tick handler, which runs off the timer and not the frame loop. The rate is
  # written on the `timer` and nowhere near the body, so a reader of the handler has no way
  # to see that at 4000 a second it runs 67 times a frame.
  TICKS = lambda do |with|
    screen :bitmap
    clear_screen :black
    n = var :n, 0
    timer(:beat, per_second: TICK_HZ).on_tick { n.add 1 } if with
    game_loop { }
  end

  # A whole frame of ordinary game work — transfers, plotted glyphs and arithmetic — rather
  # than one standing cost on its own. This is the case that catches a weight that drifted
  # somewhere in the op tree, where the others cannot look.
  FRAME = lambda do |with|
    screen :bitmap
    n = var :n, 0
    game_loop do
      if with
        20.times { |i| dma_fill_rect 0, (i * 6) % 150, 220, 2, :red }
        draw_text "SCORE 1234", 8, 8, :white
        40.times { n.add 1 }
      end
    end
  end

  # A frame of nothing but instructions, which is the case that gains the WHOLE of what the
  # quick memory is worth. The frame above gains almost none of it, because a transfer is not
  # instructions — and getting that difference right is the whole of the pair of tests at the
  # bottom of this file.
  #
  # :first is declared and never used, here and in the two fixtures below it. Reaching a
  # variable starts by building its address, and the FIRST variable of a program sits at an
  # address the console builds in one instruction where every later one takes two — so a
  # statement touching the first variable is an instruction cheaper at each end than the same
  # statement anywhere else. Exactly one variable in a program is like that, so the weights are
  # measured where the other variables are, and a fixture that used the first one would be
  # checking the one case the model deliberately over-charges.
  # HOW MANY, and it is not arbitrary — it is squeezed from both ends.
  #
  # From below: SLACK is there for the small fixed costs that survive the differencing, and in
  # a fixture of a few scanlines it is most of what the check allows, so a weight a quarter out
  # would still pass. Past about six hundred the band decides instead of the slack — and a
  # quarter out is exactly what op_step was, measured on the program's FIRST variable (the one
  # variable whose address the console builds in a single instruction rather than two).
  #
  # From above: the arithmetic fixture is also built HOT, and a routine only gains the quick
  # memory if it fits there. Nine hundred of these no longer do.
  PLAIN_STATEMENTS = 800

  ARITHMETIC = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    game_loop { PLAIN_STATEMENTS.times { n.add 1 } if with }
  end

  # The OTHER shape of plain statement. An `add` reaches its variable at both ends — read it,
  # change it, write it back — where a `set` only reaches it to write. Two thirds of the work,
  # and one weight was charged for both until it was measured.
  ASSIGNMENTS = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    m = var :m, 7
    game_loop { PLAIN_STATEMENTS.times { n.set m } if with }
  end

  # THE SAME ASSIGNMENTS, in a program that declares a list. Reaching a variable begins by
  # building its address, and how many instructions that takes depends on the address: two for
  # an ordinary variable, three for one past the first 256 bytes of the console's quick memory.
  # A list of 64 items claims that whole 256 bytes before any variable gets a home, so every
  # variable here is the dearer kind and every statement pays it at both ends — the read and
  # the write. That is a quarter more than the same statements without the list, and the model
  # used to charge one price for both.
  #
  # The list is declared and never used: what is under test is where the variables landed, not
  # what a list costs.
  FAR_VARIABLES = lambda do |with|
    screen :bitmap
    list :xs, capacity: 64
    n = var :n, 0
    m = var :m, 7
    game_loop { PLAIN_STATEMENTS.times { n.set m } if with }
  end

  # An OPERATOR, which is charged beside the statement that holds it rather than instead of
  # it. Building an operator's weight out of a statement charged the statement twice, and that
  # is what made `n.set(m + 1)` — a shape every game writes — read a third over.
  PLAIN_OPERATORS = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    m = var :m, 7
    game_loop { 200.times { n.set(m + 1) } if with }
  end

  # A COMPARISON, which is dearer than an add and used to be charged the same. Adding two
  # numbers IS the answer; comparing them only sets the console's flags, and turning those into
  # a 1 or a 0 takes a jump over one of them. Nothing else here compares, so this case is the
  # only thing watching that weight — and comparisons are not a corner: every `.then` has one.
  COMPARISONS = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    m = var :m, 7
    game_loop { 200.times { (m > 1).then { n.set 1 } } if with }
  end

  # THE SAME OPERATOR HANDED TWO DIFFERENT OPERANDS: a number written into the program, and a
  # second variable. Reading a variable is three instructions where the number is one, and
  # every weight in the model was measured with whichever of the two its own benchmark held —
  # so a weight can pay for one read and never for two. These two fixtures differ in that
  # operand and in nothing else, which is what makes their difference the read alone.
  #
  # THE SAME COUNT ON BOTH SIDES, and the spare `p` declared on both, so the two programs
  # place their variables alike and nothing but the operand is left between them.
  ONE_READ = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    m = var :m, 7
    var :p, 3
    game_loop { PLAIN_STATEMENTS.times { n.set(m + 1) } if with }
  end

  TWO_READS = lambda do |with|
    screen :bitmap
    var :first, 0
    n = var :n, 0
    m = var :m, 7
    p = var :p, 3
    game_loop { PLAIN_STATEMENTS.times { n.set(m + p) } if with }
  end

  # A rectangle that starts on an ODD column of the tear-free screen. A pixel there is one
  # byte and video memory refuses to write a lone byte, so a rectangle whose first pixel is
  # the far half of a pair has that pixel — and the one at its far end — read, changed and
  # written back one at a time, with the run between them reached past both.
  #
  # FOUR PIXELS WIDE ON PURPOSE. That makes a row all three of its pieces — an end, a pair,
  # an end — where a wider one would be mostly run and a two-pixel one mostly ends. A third
  # of what this row costs is in the ends' own work, so the fixture notices when that work
  # goes missing. It used to: the two ends were charged one averaged figure, and finding
  # each piece of a row cost nothing, and the rectangle read at seven tenths of its cost.
  TEARFREE_ODD = lambda do |with|
    screen :bitmap, tear_free: true
    y = var :y, 10
    game_loop { 20.times { draw_rect_at 41, y, 4, 16, :red } if with }
  end

  # The same rectangle one column left, which splices nothing: eight pixels starting on an
  # even column are four whole pairs. The cheap case, and it has to STAY cheap — an odd
  # column costs about three times an even one, so a fix that simply charged more everywhere
  # would show up here.
  TEARFREE_EVEN = lambda do |with|
    screen :bitmap, tear_free: true
    y = var :y, 10
    game_loop { 20.times { draw_rect_at 40, y, 8, 16, :red } if with }
  end

  # Reading elements out of a list, which was priced at NOTHING until it was measured — on
  # the grounds that a read is a single load. It is thirteen instructions: a list element
  # sits in a ring, so reaching it means the head, the wrap, the scale to bytes and the base
  # before anything is loaded. Nothing else here reads a list, so this case is the only thing
  # watching that weight.
  LIST_READS = lambda do |with|
    screen :bitmap
    xs = list :xs, capacity: 64
    64.times { |i| xs << i }
    out = var :out, 0
    i = var :i, 3
    game_loop { 60.times { out.set xs[i] } if with }
  end

  # And a TABLE read, at the length that makes it the DEARER of its two shapes: 60 is not a
  # power of two, so an out-of-range index is clamped to the ends with a compare and a branch
  # per bound rather than wrapped with one mask. That is the shape most hand-written tables
  # have, and it costs twice the other one.
  TABLE_READS = lambda do |with|
    screen :bitmap
    t = table :nums, (0...60).to_a
    out = var :out, 0
    i = var :i, 3
    game_loop { 60.times { out.set t[i] } if with }
  end

  # A frame of the cheapest arithmetic there is: multiplying by a power of two, which the
  # build turns into a shift. It was charged a whole plain step — six instructions for one —
  # so `set :y, (x * 8)` read at twice what it costs. Nothing else here shifts, and the
  # ARITHMETIC case above is adds, so this is the only thing watching that weight.
  SHIFTS = lambda do |with|
    screen :bitmap
    x = var :x, 7
    y = var :y, 0
    game_loop { 500.times { y.set(x * 8) } if with }
  end

  CASES = [
    Standing.new(name: :mixer, weight: :mix_voice_sample, fast_code: false, shape: MIXER,
                 predict: ->(model, program) { model.mixer_verdict(program)&.fetch(:cost) || 0 }),
    Standing.new(name: :bend, weight: :bend_line, fast_code: false, shape: BEND,
                 predict: ->(model, program) { model.bend_cost(program) }),
    Standing.new(name: :bend_fast, weight: :bend_line_fast, fast_code: true, shape: BEND,
                 predict: ->(model, program) { model.bend_cost(program) }),
    Standing.new(name: :ticks, weight: :tick_interrupt, fast_code: false, shape: TICKS,
                 predict: ->(model, program) { model.tick_cost(program) }),
    Standing.new(name: :ticks_fast, weight: :tick_interrupt_fast, fast_code: true, shape: TICKS,
                 predict: ->(model, program) { model.tick_cost(program) }),
    Standing.new(name: :frame, weight: :dma_pixel, fast_code: false, shape: FRAME,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :arithmetic, weight: :fast_code_speedup, fast_code: true, shape: ARITHMETIC,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :tearfree_odd, weight: :tearfree_edge_near, fast_code: false, shape: TEARFREE_ODD,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :tearfree_even, weight: :tearfree_pair, fast_code: false, shape: TEARFREE_EVEN,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :list_reads, weight: :list_read, fast_code: false, shape: LIST_READS,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :table_reads, weight: :table_read_clamped, fast_code: false, shape: TABLE_READS,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :shifts, weight: :op_mul_pow2, fast_code: false, shape: SHIFTS,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :plain_ops, weight: :op_plain, fast_code: false, shape: PLAIN_OPERATORS,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :comparisons, weight: :op_compare, fast_code: false, shape: COMPARISONS,
                 predict: ->(model, program) { model.frame_cost(program) }),
    Standing.new(name: :far_vars, weight: :var_address_step, fast_code: false, shape: FAR_VARIABLES,
                 predict: ->(model, program) { model.frame_cost(program) }),
  ].freeze

  def test_each_standing_cost_matches_what_the_emulator_measures
    CASES.each do |standing|
      predicted = predict(standing)
      measured = measure(standing)
      assert_operator measured, :>, SLACK, "#{standing.name}: the fixture has to do measurable work"
      assert_in_delta predicted, measured, (predicted * BAND) + SLACK,
                      "#{standing.name}: the model predicts ~#{predicted.round(2)} scanlines and the " \
                      "emulator measures #{measured.round(2)} — :#{standing.weight} has drifted from " \
                      "reality. Re-run tools/calibrate_cost_model.rb and commit the diff."
    end
  end

  # The claim that makes this worth more than a smoke test. Each case has to be watching
  # its OWN weight: break one weight and exactly one case may notice. Without this a case
  # could be passing on a prediction that never reads the weight it names, and the whole
  # file would agree with the emulator while guarding nothing.
  def test_a_drifted_weight_fails_its_own_case_and_no_other
    CASES.each do |broken|
      CASES.each do |watching|
        predicted = predict(watching, drift: broken.weight)
        measured = measure(watching)
        noticed = (predicted - measured).abs > (predicted * BAND) + SLACK
        if broken.name == watching.name
          assert noticed, ":#{broken.weight} was tripled and the #{watching.name} case did not " \
                          "notice — it does not depend on the weight it claims to watch"
        else
          refute noticed, ":#{broken.weight} was tripled and the #{watching.name} case failed too — " \
                          "the cases overlap, so a failure here will not say which weight drifted"
        end
      end
    end
  end

  # A reading cannot count past a frame's worth of work: past ~228 scanlines it caps out,
  # and then a prediction that is twice the truth reads as agreement. Every fixture is
  # sized to leave that regime far behind, and this is what keeps it that way as they grow.
  def test_the_readings_stay_well_inside_a_frame
    ceiling = CostModel::FRAME_BUDGET * ROOM_IN_A_FRAME
    CASES.each do |standing|
      assert_operator measure(standing), :<, ceiling,
                      "#{standing.name}: the fixture measures too near a whole frame, where the " \
                      "reading saturates and a real divergence would read as agreement. Make it smaller."
    end
  end

  # WHAT THE QUICK MEMORY IS AND IS NOT WORTH, which is one claim in two halves and was got
  # wrong in both directions at once until it was measured.
  #
  # A routine kept in the console's quick memory runs about two and a half times faster. That
  # is true of INSTRUCTIONS. A transfer is not instructions: the CPU writes a few registers to
  # set a copy going and is then stopped while a separate engine moves the pixels, so where our
  # code lives changes nothing about how long that takes. Charging the whole speed-up against
  # a transfer made four of the examples estimate at four tenths of the measured frame, and in
  # the direction that matters — a game the estimate called comfortable would tear.
  #
  # So: the same transfer frame built both ways, each in band, and the real gain far short of
  # the full factor.
  def test_a_frame_of_transfers_is_priced_right_wherever_its_routine_lives
    cold = frame_case(:frame, fast_code: false)
    hot = frame_case(:frame_hot, fast_code: true)
    assert_includes rom_for(hot, true).placement[:funcs], :__frame,
                    "this test is about a frame whose loop moved; this one did not"

    [cold, hot].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: a frame of transfers is mispriced when its routine " \
                      "#{standing.fast_code ? 'moves into' : 'stays out of'} the quick memory"
    end
    assert_operator measure(cold) / measure(hot), :<, 2.0,
                    "a frame of transfers gains far less than the full speed-up, and if it no " \
                    "longer does then this fixture stopped being mostly transfers"
  end

  # The other half: a frame of nothing but instructions still gains all of it. Getting the
  # transfer case right by simply charging less everywhere would break this one.
  def test_a_frame_of_arithmetic_still_gains_the_whole_speed_up
    cold = statement_case(:arith_cold, ARITHMETIC, :op_step)
    hot = CASES.find { |c| c.name == :arithmetic }

    [cold, hot].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: a frame of arithmetic is mispriced"
    end
    assert_in_delta CostModel::DEFAULT_WEIGHTS[:fast_code_speedup], measure(cold) / measure(hot), 0.5,
                    "moving a frame of instructions into the quick memory is worth the measured " \
                    "factor, and the model has to keep charging it"
  end

  # THE TWO SHAPES OF PLAIN STATEMENT, which one weight was charged for until it was measured.
  # `add :n, 1` reaches its variable at both ends; `set :n, m` only reaches it to write. So a
  # frame of assignments has to measure LESS than a frame of the same many changes, and each
  # has to be priced as what it is.
  #
  # These are not CASES: a statement weight is an ingredient of nearly every other fixture
  # here — every read, every shift, every branch body is a statement — so no fixture can watch
  # one and leave the others alone, which is what the drift matrix above wants. They get a test
  # of their own instead, and it names the weight that moved just as clearly. The changing side
  # is the same cold arithmetic frame the speed-up test above reads, measured once for both.
  def test_a_statement_that_only_writes_costs_less_than_one_that_changes
    changed = statement_case(:arith_cold, ARITHMETIC, :op_step)
    written = statement_case(:assigns, ASSIGNMENTS, :op_assign)

    [changed, written].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: a frame of plain statements is mispriced — " \
                      ":#{standing.weight} has drifted from reality"
    end
    assert_operator measure(written), :<, measure(changed),
                    "only writing a variable has to cost less than changing one, or these are " \
                    "not two weights and the split that made them is wrong"
  end

  # THE SECOND VARIABLE A STATEMENT READS, which the model charged nothing for. The claim here
  # is the DIFFERENCE between the two fixtures rather than either of them on its own, and that
  # is not a stylistic choice: two instructions in twelve sits well inside the band a single
  # fixture is judged by, so a fixture reading a second variable would have passed while the
  # model paid for one of them. Differenced, everything the pair shares — the statement, the
  # operator, the loop, the first read — cancels, and what is left is the second read.
  #
  # This is not a CASE, for the reason the statement weights above are not: a variable read is
  # an ingredient of nearly every other fixture here, so no fixture can watch it and leave the
  # others alone, which is what the drift matrix wants.
  def test_a_statement_is_charged_for_every_variable_it_reads
    one = statement_case(:one_read, ONE_READ, :var_operand)
    two = statement_case(:two_reads, TWO_READS, :var_operand)

    predicted = predict(two) - predict(one)
    measured = measure(two) - measure(one)
    assert_operator measured, :>, SLACK, "reading a second variable has to be measurable work"
    assert_in_delta predicted, measured, (predicted * BAND) + SLACK,
                    "over #{PLAIN_STATEMENTS} statements the model says a second variable read " \
                    "costs ~#{predicted.round(2)} scanlines and the emulator measures " \
                    "#{measured.round(2)} — :var_operand has drifted from reality. " \
                    "Re-run tools/calibrate_cost_model.rb and commit the diff."
  end

  # A COLUMN THE GAME WORKS OUT, WHOSE PARITY IS STILL PROVABLE. A game on a grid writes
  # `cell * 8`, and eight times anything is even however the game works `cell` out — so the
  # even row is the only one that can run, and both the backend and the model say so from
  # the same proof (IR::Parity).
  #
  # This is a claim about the console, not about the model agreeing with itself: it is only
  # worth making if a rectangle at a proved column really does cost what the written-in one
  # costs. Charging the dearer row instead over-charged it by three. So the pair is measured
  # here — the proof against the emulator, and the refusal beside it, which must still be
  # charged the dearer row because three times a number is even or odd as that number is.
  #
  # These are not CASES: their prediction rests on the same weights the two written-in
  # columns already watch, and the drift matrix above wants one watcher per weight.
  def test_a_column_proved_even_costs_what_the_written_in_even_column_costs
    proved = grid_case(:tf_grid, 8)
    refused = grid_case(:tf_nogrid, 3)

    [proved, refused].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: a rectangle at `cell * #{standing.name == :tf_grid ? 8 : 3}` " \
                      "is mispriced — the parity proof and the emulator disagree"
    end
    assert_operator measure(refused) / measure(proved), :>, 2.0,
                    "an odd column really is several times an even one, which is what makes " \
                    "proving it worth doing; if it is not, this fixture stopped being about parity"
  end

  private

  # The same rectangle a grid game draws, at `cell * times`. With an even multiplier the
  # column is proved even; with an odd one nothing is proved and the game runs it at an odd
  # column, so the pair covers the proof and the refusal on the same shape.
  def grid_case(name, times)
    shape = lambda do |with|
      screen :bitmap, tear_free: true
      cell = var :cell, 5
      y = var :y, 10
      game_loop { 20.times { draw_rect_at cell * times, y, 8, 16, :red } if with }
    end
    Standing.new(name: name, weight: :tearfree_pair, fast_code: false, shape: shape,
                 predict: ->(model, program) { model.frame_cost(program) })
  end

  def frame_case(name, fast_code:)
    Standing.new(name: name, weight: :dma_pixel, fast_code: fast_code, shape: FRAME,
                 predict: ->(model, program) { model.frame_cost(program) })
  end

  # A fixture priced by its whole frame, for the tests that stand outside CASES.
  def statement_case(name, shape, weight)
    Standing.new(name: name, weight: weight, fast_code: false, shape: shape,
                 predict: ->(model, program) { model.frame_cost(program) })
  end

  # What the model says this case's one thing costs, asked of a model that knows how the
  # ROM was built. +drift+ names a weight to triple first.
  def predict(standing, drift: nil)
    rom = rom_for(standing, true)
    overrides = drift ? { drift => CostModel::DEFAULT_WEIGHTS.fetch(drift) * DRIFT } : {}
    standing.predict.call(rom.cost_model(**overrides), rom.source_program)
  end

  # The measured cost of the one thing: the whole frame with it, minus the whole frame
  # without it. Everything the pair shares cancels.
  def measure(standing)
    self.class.measurements[standing.name] ||=
      frame_scanlines(rom_for(standing, true)) - frame_scanlines(rom_for(standing, false))
  end

  # Building and measuring a ROM never changes its answer, so every case's two ROMs and
  # two readings are made once and shared by every test in the file.
  def self.measurements = @measurements ||= {}
  def self.roms = @roms ||= {}

  def rom_for(standing, with)
    self.class.roms[[standing.name, with]] ||= begin
      shape = standing.shape
      RubyGBA.build(standing.name.to_s.upcase[0, 12], code: code_for(standing, with), maker: "01",
                    fast_code: standing.fast_code, err: StringIO.new) { instance_exec(with, &shape) }
    end
  end

  def code_for(standing, with)
    "#{with ? 'B' : 'C'}#{standing.name.to_s.upcase.delete('_')}".ljust(4, "X")[0, 4]
  end

  # What one frame of this ROM costs the console, read the way the profiler reads it —
  # whichever of the two clocks is higher, since each is blind to something the other sees
  # (see Analyzer#frame_scanlines). The smallest of three windows, so a one-off wobble
  # cannot pass for a cost.
  def frame_scanlines(rom)
    require_gemba_core!
    Dir.mktmpdir do |dir|
      path = File.join(dir, "calibration.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(10) # settle: reach the steady state before reading anything
      reading = 3.times.map do
        20.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max
      end.min
      probe.close
      return reading
    end
  end
end
