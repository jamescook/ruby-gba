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

  # FOUR backgrounds bending row by row, which is what puts the answering ON THE INTERRUPT:
  # three is as many copying engines as there are to lend out, so a fourth layer is one more
  # than there is an engine for and the display interrupts the program after every line it
  # counts. None of that is a statement anybody wrote in the frame, which is why it has to be
  # measured whole rather than found in the op tree.
  #
  # THIS CASE CANNOT WATCH ITS WEIGHT ALONE, and that is the hardware and not the fixture:
  # a program only reaches the interrupt by bending more layers than there are engines, and
  # every one of those layers has a table to fill. So it moves for :bend_row_copied as well
  # — see the note on the drift matrix, which is written around that.
  BEND = lambda do |with|
    screen :tiled
    image(:sky, "." => :blue) { ("." * 8 + "\n") * 8 }
    tiles :set, "." => :sky
    4.times do |i|
      water = background :"water#{i}", tiles: :set, map: Array.new(20) { "." * 30 }
      water.scroll_each_row { |_row| 3 } if with
    end
    game_loop { }
  end

  # ONE bending layer, which an engine feeds — so there is no interrupt anywhere and the
  # whole reading is the table being filled.
  #
  # A NUMBER WRITTEN IN THE PROGRAM as the offset, and that is not laziness: with nothing to
  # work out per row the whole reading is the table, so the case watches its own weight and
  # nothing else. Read a table here instead and the block's own arithmetic — which the model
  # prices from the op tree, at the general quick-memory factor — grows into a share big
  # enough that this case notices THAT weight drifting too, and then a failure no longer says
  # which. It is also the block the weight was measured on (Benchmarks#bend_layers_busy).
  BEND_COPIED = lambda do |with|
    screen :tiled
    image(:sky, "." => :blue) { ("." * 8 + "\n") * 8 }
    tiles :set, "." => :sky
    water = background :water, tiles: :set, map: Array.new(20) { "." * 30 }
    water.scroll_each_row { |_row| 3 } if with
    game_loop { }
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
  # HOW MANY, and it is not arbitrary — it is squeezed from both ends.
  #
  # From below: SLACK is there for the small fixed costs that survive the differencing, and in
  # a fixture of a few scanlines it is most of what the check allows, so a weight a quarter out
  # would still pass. Past about six hundred the band decides instead of the slack — and a
  # quarter out is exactly what op_step once was, so a fixture too small to tell would have let
  # it through.
  #
  # From above: the arithmetic fixture is also built HOT, and a routine only gains the quick
  # memory if it fits there. Nine hundred of these no longer do.
  PLAIN_STATEMENTS = 800

  ARITHMETIC = lambda do |with|
    screen :bitmap
    n = var :n, 0
    game_loop { PLAIN_STATEMENTS.times { n.add 1 } if with }
  end

  # The OTHER shape of plain statement. An `add` reaches its variable at both ends — read it,
  # change it, write it back — where a `set` only reaches it to write. Two thirds of the work,
  # and one weight was charged for both until it was measured.
  ASSIGNMENTS = lambda do |with|
    screen :bitmap
    n = var :n, 0
    m = var :m, 7
    game_loop { PLAIN_STATEMENTS.times { n.set m } if with }
  end

  # THE SAME ASSIGNMENTS, in a program that declares a list — so that every variable in it sits
  # far from the start of the console's quick memory, a list of 64 items having claimed the
  # first 256 bytes before any variable got a home.
  #
  # IT COSTS THE SAME, and that is the whole point of the case. Reaching a variable once began
  # by building its whole address, and how many instructions that took depended on the address:
  # one for the very first variable, two for the next sixty-three, three past that. So these
  # statements cost a quarter more than the same statements without the list, and which
  # variables a program paid extra for came down to the order the build happened to emit things
  # in. A read now names the base of the variable memory and carries the distance inside the
  # load, so the hundredth variable costs what the first does.
  #
  # The list is declared and never used: what is under test is where the variables landed, not
  # what a list costs.
  ASSIGNMENTS_PAST_A_LIST = lambda do |with|
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
    n = var :n, 0
    m = var :m, 7
    game_loop { 200.times { (m > 1).then { n.set 1 } } if with }
  end

  # THE SAME WORK, DIVIDED INTO LOOPS TWO WAYS. Both do 240 passes of the same body a frame;
  # one does it in sixty short loops and the other in six long ones. A loop costs a rate per
  # pass AND a fixed amount for being entered, so the sixty-loop frame really is dearer — and
  # a model that priced only the pass would say the two were the same.
  SHORT_LOOPS = lambda do |with|
    screen :bitmap
    n = var :n, 0
    b = self
    game_loop { 60.times { b.repeat(4) { n.add 1 } } if with }
  end

  LONG_LOOPS = lambda do |with|
    screen :bitmap
    n = var :n, 0
    b = self
    game_loop { 6.times { b.repeat(40) { n.add 1 } } if with }
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
    n = var :n, 0
    m = var :m, 7
    var :p, 3
    game_loop { PLAIN_STATEMENTS.times { n.set(m + 1) } if with }
  end

  TWO_READS = lambda do |with|
    screen :bitmap
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

  # A FRAME THAT SCROLLS HARD: the window over a background is moved this many times, and the
  # write that moves it is made ONCE — in the gap between frames, which is what stops scrolling
  # tearing. So nearly all of this frame is the game's own statements and the loop around them,
  # priced where they are written, and the write is a fortieth of a scanline on top of that.
  #
  # ENOUGH OF THEM THAT THE BAND DECIDES. A single fixture is judged by a quarter of its
  # prediction PLUS a scanline of slack, and in a small frame the slack is nearly all of that —
  # so a few scrolls would pass whatever the model said about them. At this many the quarter is
  # what the check turns on, and a frame charged a write per CALL reads half again too dear and
  # fails.
  SCROLLS_PER_FRAME = 200

  SCROLLING = lambda do |with|
    screen :tiled
    image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
    tiles :set, "#" => :tile
    world = background :world, tiles: :set, map: Array.new(20) { "#" * 30 }
    b = self
    game_loop { b.repeat(SCROLLS_PER_FRAME) { world.scroll_by 1, 0 } if with }
  end

  # KEEPING SPRITES OUT OF A PLACED FADE, which is the one member of the fade family that is
  # not free — the rest tell the display what to show and redraw nothing. The console names
  # every sprite with a single bit in the register a fade writes, so "all of them except these"
  # cannot be said there: each kept sprite gets a second, invisible entry in the sprite table,
  # in the shape of its own pixels, and the fade goes around it.
  #
  # The two sides declare the same sprites in the same layers and differ only in whether the
  # fade is placed, so the difference is the windows and nothing else. ONE SPRITE STAYS BELOW
  # THE LINE: a fade that keeps every sprite has nothing left to fade and makes no window.
  KEPT_SPRITES = 63

  KEEPING = lambda do |with|
    screen :tiled
    image(:dot, "#" => :red) { (["#" * 8] * 8).join("\n") }
    layers :field, :ui
    layer(:field) { sprite :dot, at: [0, 0] }
    layer(:ui) { KEPT_SPRITES.times { |i| sprite :dot, at: [((i + 1) % 28) * 8, ((i + 1) / 28) * 8] } }
    fade :black, 100, under: :ui if with
    game_loop { }
  end

  # A frame of the cheapest arithmetic there is: multiplying by a power of two, which the
  # build turns into a shift. It was charged a whole plain step — six instructions for one —
  # so `set :y, (x * 8)` read at twice what it costs. Nothing else here shifts, and the
  # ARITHMETIC case above is adds, so this is the only thing watching that weight.
  #
  # FOUR SHIFTS TO A STATEMENT, not one, so that the case is actually ABOUT shifting. With one
  # the shift was a fifth of what the frame cost and the statement around it was the rest — and
  # a case that is four parts something else cannot notice its own weight drifting, which is the
  # one thing it exists to do. Sharing a single write and a single read between four shifts puts
  # the weight in the majority.
  SHIFTS = lambda do |with|
    screen :bitmap
    x = var :x, 7
    y = var :y, 0
    game_loop { 500.times { y.set(x * 8 * 8 * 8 * 8) } if with }
  end

  CASES = [
    Standing.new(name: :mixer, weight: :mix_voice_sample, fast_code: false, shape: MIXER,
                 predict: ->(model, program) { model.mixer_verdict(program)&.cost || 0 }),
    Standing.new(name: :bend, weight: :bend_line, fast_code: false, shape: BEND,
                 predict: ->(model, program) { model.bend_cost(program) }),
    Standing.new(name: :bend_fast, weight: :bend_line_fast, fast_code: true, shape: BEND,
                 predict: ->(model, program) { model.bend_cost(program) }),
    Standing.new(name: :bend_copied, weight: :bend_row_copied, fast_code: false, shape: BEND_COPIED,
                 predict: ->(model, program) { model.bend_cost(program) }),
    Standing.new(name: :bend_copied_fast, weight: :bend_row_copied_fast, fast_code: true, shape: BEND_COPIED,
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
    Standing.new(name: :keeping, weight: :obj_window_write, fast_code: false, shape: KEEPING,
                 predict: ->(model, program) { model.kept_sprites_cost(program) }),
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

  # The claim that makes this worth more than a smoke test: A FAILURE HERE HAS TO SAY WHICH
  # WEIGHT DRIFTED. Break one weight and the set of cases that notice is asked for twice —
  # it must contain the case that names that weight, and it must not be a set any OTHER
  # weight also produces. Without this a case could be passing on a prediction that never
  # reads the weight it names, and the whole file would agree with the emulator while
  # guarding nothing.
  #
  # ONE SET RATHER THAN ONE CASE, because one pair of weights cannot be told apart by any
  # fixture. A program is only answered per line when it bends more layers than there are
  # copying engines to feed them, and every one of those layers has a table to fill — so
  # :bend_row_copied moves the interrupt case as well as its own, and there is no program
  # that shows the one without the other. It is still diagnostic, because the sets differ:
  # the table's drift fails both bending cases and the interrupt's fails one.
  def test_a_drifted_weight_says_which_weight_drifted
    signatures = CASES.to_h do |broken|
      noticing = CASES.select do |watching|
        predicted = predict(watching, drift: broken.weight)
        (predicted - measure(watching)).abs > (predicted * BAND) + SLACK
      end
      [broken, noticing.map(&:name)]
    end

    signatures.each do |broken, noticing|
      assert_includes noticing, broken.name,
                      ":#{broken.weight} was tripled and the #{broken.name} case did not notice — " \
                      "it does not depend on the weight it claims to watch"
      twin = signatures.find { |other, set| other != broken && set == noticing }
      assert_nil twin, ":#{broken.weight} and :#{twin&.first&.weight} fail the same cases " \
                       "(#{noticing.join(', ')}), so a failure here will not say which drifted"
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
    assert_includes rom_for(hot, true).placement.funcs, :__frame,
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

  # WHERE A VARIABLE SITS COSTS NOTHING, and this is the case that says so on the console rather
  # than in the model.
  #
  # It used to cost a great deal. Reaching a variable began by building its whole address, and
  # how many instructions that took depended on the address itself — one for the very first
  # variable, two for the next sixty-three, three past that. A list of 64 items claims the first
  # 256 bytes before any variable gets a home, so declaring one pushed every variable in the
  # program into the dearest group and made every statement touching one cost a quarter more.
  # Which variables a game paid extra for came down to the order the build happened to emit
  # things in, which is not something an author can see, reason about or do anything about.
  #
  # The same statements, with and without a list in front of them, now cost the same. This is
  # the only test that would notice that going away, and it is measured on the emulator: the
  # model cannot be the witness here, because the model's answer is a weight this change
  # deleted.
  def test_where_a_variable_sits_costs_nothing
    near = statement_case(:assigns, ASSIGNMENTS, :op_assign)
    far = statement_case(:far_vars, ASSIGNMENTS_PAST_A_LIST, :op_assign)

    assert_operator measure(near), :>, SLACK, "the statements have to be measurable work at all"
    assert_in_delta measure(near), measure(far), (measure(near) * BAND) + SLACK,
                    "#{PLAIN_STATEMENTS} assignments cost #{measure(near).round(2)} scanlines with " \
                    "their variables at the front of the quick memory and #{measure(far).round(2)} " \
                    "with a list pushing them past the first 256 bytes. Those should now be the " \
                    "same: a variable is reached from a base held in a register, so the hundredth " \
                    "costs what the first does."
  end

  # A SHORT LOOP IS NOT A LONG ONE CUT DOWN. Entering a loop costs about twenty instructions —
  # working the trip count out into a hidden limit, zeroing a hidden counter, the branch that
  # leaves — and a loop of four pays that over four passes where a loop of four hundred spreads
  # it to nothing. Charged per pass alone, the short frame here read an eighth light while the
  # long one read true, which is the shape of a missing fixed cost.
  #
  # These are not CASES: loop_start is a sixth of a short-loop frame at most, so tripling it
  # stays inside the band a single fixture is judged by and the drift matrix could not watch
  # it. What guards the weight sharply is the model-level test that a loop of one costs the
  # entering plus one pass; what this guards is that the two agree with the console at all.
  def test_a_short_loop_and_a_long_one_are_both_priced_right
    short = statement_case(:short_loops, SHORT_LOOPS, :loop_start)
    long = statement_case(:long_loops, LONG_LOOPS, :loop_pass)

    [short, long].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: the same 240 passes a frame, in loops of " \
                      "#{standing.name == :short_loops ? 'four' : 'forty'} — mispriced"
    end
    assert_operator measure(short), :>, measure(long),
                    "sixty loops really do cost more than six of the same total length, or " \
                    "there is nothing here to price"
  end

  # A FRAME OF SCROLLING ADDS UP, which is a different claim from the two above and needs its
  # own shape. Moving a background's window costs two register writes a frame — a fortieth of a
  # scanline — so no fixture the emulator can read will ever notice that weight moving: a
  # single frame is judged with a whole scanline of slack. That number is guarded exactly
  # instead, against canned readings, in test_cost_calibration_tool.rb.
  #
  # What the console can say is that the frame AROUND it is right. A game that scrolls two
  # hundred times pays two hundred passes and four hundred statements and ONE write, and the
  # first two are priced where they are written — so a scroll charged per call would be paying
  # for that loop twice, once as itself and once as the write. Here the sum has to land.
  #
  # It is not a CASE for the same reason the statement weights are not: what it leans on is the
  # loop and the plain statements every other fixture leans on too, and the drift matrix wants
  # one watcher per weight.
  def test_a_frame_that_scrolls_hard_adds_up
    scrolling = statement_case(:scrolling, SCROLLING, :scroll_write)

    assert_operator measure(scrolling), :>, SLACK, "the fixture has to do measurable work"
    assert_in_delta predict(scrolling), measure(scrolling), (predict(scrolling) * BAND) + SLACK,
                    "a frame of #{SCROLLS_PER_FRAME} scrolls is mispriced — the model predicts " \
                    "~#{predict(scrolling).round(2)} scanlines and the emulator measures " \
                    "#{measure(scrolling).round(2)}"
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
