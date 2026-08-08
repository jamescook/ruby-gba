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
  ARITHMETIC = lambda do |with|
    screen :bitmap
    n = var :n, 0
    game_loop { 500.times { n.add 1 } if with }
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
    cold = Standing.new(name: :arith_cold, weight: :op_step, fast_code: false, shape: ARITHMETIC,
                        predict: ->(model, program) { model.frame_cost(program) })
    hot = CASES.find { |c| c.name == :arithmetic }

    [cold, hot].each do |standing|
      assert_in_delta predict(standing), measure(standing), (predict(standing) * BAND) + SLACK,
                      "#{standing.name}: a frame of arithmetic is mispriced"
    end
    assert_in_delta CostModel::DEFAULT_WEIGHTS[:fast_code_speedup], measure(cold) / measure(hot), 0.5,
                    "moving a frame of instructions into the quick memory is worth the measured " \
                    "factor, and the model has to keep charging it"
  end

  private

  def frame_case(name, fast_code:)
    Standing.new(name: name, weight: :dma_pixel, fast_code: fast_code, shape: FRAME,
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
