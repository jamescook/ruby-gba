# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# THE TEST THE CORPUS CANNOT GIVE: does the estimate say OVER when the console really cannot
# finish the frame?
#
# Every example in examples/ fits. So a check that only reads those agrees with the console
# every time — and so would an estimate that answered "it fits" to everything. The one thing
# this model exists for is to warn an author before the console does, and with nothing to warn
# about, nothing can fail in the direction that matters. That is the gap this file closes.
#
# Each case is the SAME program at two sizes: one the console finishes and one it does not. The
# estimate has to agree about both. A case that only overran would be passed by a model that
# always cries wolf; a case that only fitted would be passed by one that never does.
#
# TWO DEADLINES SHARE A FRAME, and which one a program races decides how the console is asked:
#
#   :tearing     drawing, against the ~68-line safe window before the picture is shown. These
#                fixtures draw and do nothing else, so a frame's whole reading IS its drawing,
#                and a frame of 80 or 180 scanlines is read exactly rather than saturating.
#   :frame_rate  everything, against the whole 228-line frame. Passing THAT means the reading
#                saturates and can no longer say by how much — so the frame RATE answers it
#                instead. Below 60 means a pass missed its frame, which is the thing itself
#                rather than a proxy for it.
#
# The sizes are not round numbers picked for looks: each was found by sweeping the count until
# the console crossed, and then kept far enough past the line that a re-measurement on another
# emulator build cannot walk back over it.
class TestCostOverruns < Minitest::Test
  Cost = RubyGBA::IR::CostModel

  # A primitive, at the two sizes that bracket its deadline. +shape+ takes the count.
  Overrun = Data.define(:name, :deadline, :shape, :fits, :over)

  # How far below 60 counts as a missed frame. A game that meets every frame reads exactly 60;
  # a game that misses reads 30 (it takes two video frames per pass), so anything in between
  # is noise and this sits well clear of both.
  DROPPED = 59.0

  # --- the fixtures, one per primitive ---

  # Plain statements, which is what a game's own thinking is made of. Nothing is drawn, so
  # nothing can tear — the deadline is the frame rate.
  ARITHMETIC = lambda do |n|
    screen :bitmap
    var :first, 0 # the cheap first slot, kept clear: the weights are measured on ordinary ones
    x = var :x, 0
    b = self
    game_loop { b.repeat(n) { x.add 1 } }
  end

  # A software sprite: an image with a see-through colour, drawn a pixel at a time at a
  # position the game works out. This is what a bitmap game is mostly made of.
  BLITS = lambda do |n|
    screen :bitmap
    image(:art, "#" => :red, "." => :transparent) { (["####....", "..####.."] * 4).join("\n") }
    x = var :bx, 40
    y = var :by, 20
    b = self
    game_loop { n.times { b.blit :art, x, y } }
  end

  # A HUD of live numbers. Which of the ten glyphs each column shows is only known as the game
  # runs, so every one of them is walked out of a table — far dearer than the same characters
  # written as text, and the shape a score, a timer and a health readout all take.
  DIGITS = lambda do |n|
    screen :bitmap
    var :score, 123
    b = self
    game_loop { n.times { |i| b.draw_number :score, 8 + ((i % 8) * 24), 8 + ((i / 8) * 10), :white, digits: 3 } }
  end

  # Rectangles at a size settled while building, filled by the transfer engine a row at a time.
  FILLS = lambda do |n|
    screen :bitmap
    b = self
    game_loop { n.times { |i| b.dma_fill_rect 0, (i % 150), 200, 4, :red } }
  end

  # The same rectangle on the tear-free screen, where a pixel is one byte that cannot be
  # written on its own — a different shape of drawing entirely. Double-buffered, so it cannot
  # tear and the deadline is the frame rate.
  #
  # Sixteen pixels wide is narrow enough that each row is written out as pairs rather than
  # handed to the block-fill engine, which is most of twice as fast — so it takes a good
  # many of them to fill a frame.
  MOVING_RECTS = lambda do |n|
    screen :bitmap, tear_free: true
    y = var :ry, 20
    b = self
    game_loop { n.times { b.draw_rect_at 40, y, 16, 16, :red } }
  end

  # A walk over a list, drawing one cell per item — a snake's body, a queue of shots. The
  # count is the list's own length, so this is the shape whose cost the estimate cannot read
  # off the program (see the `usually:` hint, which is what it is told here).
  #
  # THE CLOSEST OF THESE TO ITS LINE, and worth knowing which way. At 250 items the console
  # spends 85 scanlines of its 68 and the estimate reads 71 — over, but by a twentieth where
  # the console is over by a quarter. Two things are missing from that figure and both are
  # filed: the walk's own bookkeeping, which the tear measure leaves out although it happens
  # inside the same window as the drawing it delays, and the body, which is priced under what
  # a cell costs. So this fixture is sized past where either could hide the verdict.
  LIST_WALK = lambda do |n|
    screen :bitmap
    xs = list :xs, capacity: 512, estimate: { usually: n }
    n.times { |i| xs << (i % 28) }
    b = self
    game_loop { b.repeat(xs.length) { |i| b.draw_rect_at xs[i] * 8, 40, 8, 8, :green } }
  end

  # The software mixer, which sums every sounding voice into the output buffer once a frame.
  # It touches no video memory, so it cannot tear; it just takes the frame.
  MIXER = lambda do |rate|
    screen :bitmap
    Cost::MIXER_VOICES.times do |i|
      sample(:"v#{i}", pcm: [30, -30] * 400, rate: rate).play(loop: true)
    end
    game_loop { }
  end

  CASES = [
    Overrun.new(name: :arithmetic, deadline: :frame_rate, shape: ARITHMETIC, fits: 2_000, over: 24_000),
    Overrun.new(name: :blits, deadline: :tearing, shape: BLITS, fits: 20, over: 60),
    Overrun.new(name: :digits, deadline: :tearing, shape: DIGITS, fits: 8, over: 32),
    Overrun.new(name: :fills, deadline: :tearing, shape: FILLS, fits: 20, over: 140),
    Overrun.new(name: :moving_rects, deadline: :frame_rate, shape: MOVING_RECTS, fits: 120, over: 440),
    Overrun.new(name: :list_walk, deadline: :tearing, shape: LIST_WALK, fits: 40, over: 400),
    Overrun.new(name: :mixer, deadline: :frame_rate, shape: MIXER, fits: 8_192, over: 65_536),
  ].freeze

  # THE CLAIM. At the size the console cannot finish, the estimate says so; at the size it can,
  # the estimate says that too. Both halves matter: the first is the warning this model is for,
  # and the second is what stops it being earned by crying wolf.
  def test_the_estimate_says_over_exactly_when_the_console_cannot_finish
    CASES.each do |standing|
      assert console_overruns?(standing, standing.over),
             "#{standing.name}: the fixture at #{standing.over} has to be too much for the " \
             "console, or it is not testing anything. #{reading(standing, standing.over)}"
      refute console_overruns?(standing, standing.fits),
             "#{standing.name}: the fixture at #{standing.fits} has to fit, or the pair does " \
             "not bracket the deadline. #{reading(standing, standing.fits)}"

      assert estimate_overruns?(standing, standing.over),
             "#{standing.name}: MISSED — the console cannot finish this frame and the estimate " \
             "says it fits. #{reading(standing, standing.over)}"
      refute estimate_overruns?(standing, standing.fits),
             "#{standing.name}: CRIED WOLF — the console finishes this frame and the estimate " \
             "says it does not. #{reading(standing, standing.fits)}"
    end
  end

  private

  # What the model says about the deadline this case races: the drawing against the safe
  # window, or the whole recurring load against the frame. These are the two figures the
  # report prints its verdict from (see Report#budget_summary_lines).
  def estimate_overruns?(standing, count)
    rom = rom_for(standing, count)
    program = rom.source_program
    model = rom.cost_model
    if standing.deadline == :tearing
      model.steady_tear_cost(program) > Cost::VBLANK_BUDGET
    else
      mixer = model.mixer_verdict(program)&.fetch(:cost) || 0
      model.steady_cost(program) + mixer +
        model.bend_cost(program) + model.tick_cost(program) > Cost::FRAME_BUDGET
    end
  end

  # ...and what the console says about the same deadline. A drawing fixture is read in
  # scanlines, which stay well inside a frame and so mean what they say; a whole-frame one is
  # read as a frame RATE, because past 228 the scanline reading saturates.
  def console_overruns?(standing, count)
    if standing.deadline == :tearing
      scanlines(standing, count) > Cost::VBLANK_BUDGET
    else
      frames_per_second(standing, count) < DROPPED
    end
  end

  def reading(standing, count)
    "(console #{standing.deadline == :tearing ? "#{scanlines(standing, count).round(1)} scanlines" \
                                                " of #{Cost::VBLANK_BUDGET}" \
                                              : "#{frames_per_second(standing, count)} fps"})"
  end

  # The worst frame the fixture reaches, in scanlines — CPU and the stall a transfer engine
  # imposes, whichever the frame spends its time in.
  def scanlines(standing, count)
    self.class.readings[[standing.name, count, :scanlines]] ||=
      in_temp_rom(rom_for(standing, count)) do |path|
        probe = RubyGBA::Emulator.probe(path)
        probe.step(SETTLE)
        peak = FRAMES.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max
        probe.close
        peak
      end
  end

  # The game frame rate: how many passes round the loop the program really made, counted by
  # the profiler's own instrument. 60 means every pass met its frame.
  def frames_per_second(standing, count)
    self.class.readings[[standing.name, count, :fps]] ||=
      RubyGBA::Analyzer.measure_fps(rom_for(standing, count).source_program)
  end

  SETTLE = 16 # frames to run before reading, so the game reaches its steady state
  FRAMES = 30 # frames to read, keeping the worst

  def in_temp_rom(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "overrun.gba")
      rom.write(path)
      return yield(path)
    end
  end

  # Building and reading a ROM never changes its answer, so every case's ROMs and readings are
  # made once and shared by the whole file.
  def self.readings = @readings ||= {}
  def self.roms = @roms ||= {}

  def rom_for(standing, count)
    self.class.roms[[standing.name, count]] ||= begin
      shape = standing.shape
      RubyGBA.build(standing.name.to_s.upcase[0, 12], code: code_for(standing, count), maker: "01",
                    err: StringIO.new, out: StringIO.new) { instance_exec(count, &shape) }
    end
  end

  def code_for(standing, count)
    "B#{standing.name.to_s.upcase.delete('_')}#{count}".ljust(4, "X")[0, 4]
  end
end
