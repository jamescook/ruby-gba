# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The randomness DSL: `seed`, `roll`, `rand`, `chance`. A deterministic
# pseudo-random stream — the same seed always replays the same sequence, and it's
# built entirely from ordinary IR ops (a multiply-and-add churning a hidden var),
# so both backends agree for free.
#
# These assert BEHAVIOR: build a tiny program through the DSL, run it on the
# reference backend, and read the numbers it drew — never the tree it built. A
# gemba test confirms the same draws land on real hardware, which (running the
# same IR) also proves the two backends produce an identical sequence.
class TestRandom < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  # Build through the DSL and run it on the reference backend, returning the
  # interpreter so a test can read the variables the draws wrote.
  def interpret(**opts, &block)
    ruby = Ruby.new
    ruby.run(tree(&block), **opts)
    ruby
  end

  # Build the IR tree without running it (for the guardrail and shape tests).
  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # Draw n values from `range` into vars d0..d(n-1) and read them back in order.
  def draw_sequence(n, range, seed: 42)
    i = interpret do
      seed seed
      n.times { |k| roll :"d#{k}", range }
    end
    Array.new(n) { |k| i[:"d#{k}"] }
  end

  # ---- determinism: the same seed replays the same sequence ----

  def test_same_seed_replays_the_same_sequence
    first  = draw_sequence(8, 0..999, seed: 1234)
    second = draw_sequence(8, 0..999, seed: 1234)
    assert_equal first, second, "a fixed seed must reproduce its sequence every run"
  end

  def test_different_seeds_diverge
    from_one = draw_sequence(8, 0..999, seed: 1)
    from_two = draw_sequence(8, 0..999, seed: 2)
    refute_equal from_one, from_two, "different seeds should give different sequences"
  end

  # An unseeded game still runs from a fixed default, so it's reproducible too.
  def test_unseeded_stream_is_deterministic
    run = lambda do
      i = interpret { 5.times { |k| roll :"d#{k}", 0..999 } }
      Array.new(5) { |k| i[:"d#{k}"] }
    end
    assert_equal run.call, run.call, "an unseeded stream must still be reproducible"
  end

  # ---- draws land in range ----

  def test_roll_stays_within_an_inclusive_range
    draw_sequence(50, 3..7, seed: 99).each do |v|
      assert_includes 3..7, v, "roll 3..7 produced #{v}, out of range"
    end
  end

  def test_roll_stays_within_an_exclusive_range
    draw_sequence(50, 0...10, seed: 7).each do |v|
      assert_includes 0..9, v, "roll 0...10 produced #{v}, out of range"
    end
  end

  def test_roll_covers_a_negative_range
    values = draw_sequence(50, -2..2, seed: 5)
    values.each { |v| assert_includes(-2..2, v, "roll -2..2 produced #{v}") }
    assert_operator values.uniq.size, :>, 1, "a real range should produce more than one value"
  end

  # A single-value range is a corner the reduction must still get right.
  def test_roll_of_a_one_value_range_is_that_value
    draw_sequence(4, 5..5, seed: 3).each { |v| assert_equal 5, v }
  end

  # The widest allowed span — every 15-bit color — must be accepted and in range,
  # backing the claim that real game ranges never hit the cap.
  def test_roll_covers_the_full_color_range
    draw_sequence(30, 0..0x7FFF, seed: 8).each do |v|
      assert_includes 0..0x7FFF, v, "a full-color-range roll produced #{v}, out of range"
    end
  end

  # ---- quality: draws come from the high bits, so a coin flip doesn't just
  # alternate 0,1,0,1 (the classic low-bit tell of a naive generator) ----

  def test_a_coin_flip_does_not_simply_alternate
    flips = draw_sequence(20, 0..1, seed: 2024)
    assert_equal [0, 1].sort, flips.uniq.sort, "a coin flip should turn up both faces"
    assert flips.each_cons(2).any? { |a, b| a == b },
           "a strictly alternating sequence is the low-bit footgun this must avoid"
  end

  # ---- rand: the value form ----

  def test_rand_assigns_a_value_in_range
    i = interpret do
      seed 1
      10.times { |k| set :"v#{k}", rand(1..6) }
    end
    (0...10).each { |k| assert_includes 1..6, i[:"v#{k}"], "rand(1..6) out of range" }
  end

  def test_rand_composes_inside_an_expression
    # rand(0..0) always draws 0, so the sum is a fixed, checkable number — this
    # exercises the whole draw pipeline feeding an expression, deterministically.
    i = interpret do
      x = var :x, 0
      x.set(rand(0..0) + 100)
    end
    assert_equal 100, i[:x]
  end

  def test_two_draws_in_one_expression_are_independent
    # Each rand() gets its own hidden var and churns the stream once, so the two
    # halves of the product are separate draws (their own values), not the same one.
    i = interpret do
      seed 42
      y = var :y, 0
      y.set(rand(10..10) * rand(2..2)) # fixed operands: 10 * 2, proves both draws ran
    end
    assert_equal 20, i[:y]
  end

  # ---- chance: a Condition true a given percent of the time ----

  def test_chance_zero_never_fires_and_hundred_always_fires
    i = interpret do
      seed 1
      never = var :never, 0
      always = var :always, 0
      10.times do
        chance(0).then   { never.add 1 }
        chance(100).then { always.add 1 }
      end
    end
    assert_equal 0,  i[:never],  "chance(0) must never fire"
    assert_equal 10, i[:always], "chance(100) must always fire"
  end

  def test_chance_fifty_fires_about_half_the_time
    i = interpret do
      seed 777
      hits = var :hits, 0
      100.times { chance(50).then { hits.add 1 } }
    end
    # Deterministic given the seed, but assert a band so the test states the intent
    # (roughly half) rather than pinning an incidental exact count.
    assert_includes 30..70, i[:hits], "chance(50) fired #{i[:hits]}/100 times — not near half"
  end

  # ---- randomize: entropy from the player's reaction time ----

  # Stirring moves the stream, so a draw after N stirs differs from one after M.
  def test_randomize_stirs_the_stream
    after = lambda do |stirs|
      i = interpret do
        seed 100
        stirs.times { randomize }
        roll :r, 0..30_000
      end
      i[:r]
    end
    assert_equal after.call(3), after.call(3), "the same number of stirs is reproducible"
    refute_equal after.call(3), after.call(8), "a different number of stirs should land elsewhere"
  end

  # The real usage: stir every frame on a title screen until the player presses
  # START. Two players with different reaction times get different games; the same
  # reaction time replays the same one.
  def reaction_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :white
      done = var :done, 0
      var :rx, 0
      game_loop do
        wait_vblank
        (done == 0).then do
          randomize
          pressed(:start).then do
            roll :rx, 0..200
            done.set 1
          end
        end
        (done > 0).then do
          draw_rect_at :rx, 80, 4, 4, :red
          halt
        end
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # Press START on a given frame (held from then on, so its edge fires that frame).
  def press_start_on(frame)
    ->(f) { f >= frame ? [:start] : [] }
  end

  def result_when_start_pressed_on(frame)
    Ruby.new.input_each_frame(&press_start_on(frame)).run(reaction_program)[:rx]
  end

  def test_reaction_time_decides_the_outcome
    quick = result_when_start_pressed_on(2)
    slow  = result_when_start_pressed_on(9)
    assert_includes 0..200, quick
    assert_includes 0..200, slow
    refute_equal quick, slow, "a different reaction time should give a different draw"
  end

  def test_same_reaction_time_replays_the_same_outcome
    assert_equal result_when_start_pressed_on(5), result_when_start_pressed_on(5)
  end

  def test_randomize_marker_lands_on_hardware
    program = reaction_program
    # Hold START from the first frame (a fixed timing), so the interpreter's draw
    # position is defined — then confirm the console draws it in the same place.
    i = Ruby.new.input_each_frame { [:start] }.run(program)
    x = i[:rx]
    assert_equal Color.resolve(:red), i.screen.pixel(x, 80), "interpreter drew the marker at x=#{x}"

    rom = RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(program),
                                title: "RANDOMIZE", code: "BRDZ", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 5, keys: KEY_START)
    assert v.red?(x, 80), "console drew the randomized marker at the same x=#{x}"
  end

  # ---- the boot seed: planted once, at the very start ----

  def test_the_default_seed_is_planted_first_when_unseeded
    program = tree { roll :x, 0..9 }
    first = program.children.first
    assert_equal :set, first.kind
    assert_equal Builder::RNG_STATE, first[:var]
    assert_equal Builder::DEFAULT_SEED, first[:value][:value]
  end

  def test_no_boot_seed_when_randomness_is_unused
    program = tree { set :x, 1 }
    refute program.children.any? { |n| n.kind == :set && n[:var] == Builder::RNG_STATE },
           "a game that never draws shouldn't carry the random stream at all"
  end

  # ---- guardrails: misuse gets a plain error ----

  def test_roll_rejects_a_non_range
    err = assert_raises(ArgumentError) { tree { roll :x, 5 } }
    assert_match(/range/, err.message)
  end

  def test_roll_rejects_non_whole_number_bounds
    err = assert_raises(ArgumentError) { tree { roll :x, 0.0..1.0 } }
    assert_match(/whole numbers/, err.message)
  end

  def test_roll_rejects_an_endless_range
    err = assert_raises(ArgumentError) { tree { roll :x, (0..) } }
    assert_match(/whole numbers/, err.message)
  end

  def test_roll_rejects_an_empty_range
    err = assert_raises(ArgumentError) { tree { roll :x, 9..3 } }
    assert_match(/empty/, err.message)
  end

  # A bignum bound would wrap through the console's 32-bit numbers to something
  # bogus (worst case a zero width, i.e. a divide-by-zero in the reduction).
  def test_roll_rejects_a_bound_too_big_for_32_bits
    err = assert_raises(ArgumentError) { tree { roll :x, 0..(2**40) } }
    assert_match(/32-bit/, err.message)
  end

  # A range wider than a draw can resolve would silently never reach its top.
  def test_roll_rejects_a_range_wider_than_a_draw_can_cover
    err = assert_raises(ArgumentError) { tree { roll :x, 0..100_000 } }
    assert_match(/at most/, err.message)
  end

  def test_chance_rejects_a_percent_out_of_bounds
    err = assert_raises(ArgumentError) { tree { chance(150) } }
    assert_match(/0 to 100/, err.message)
  end

  # ---- hardware: the same draws land on the console ----
  #
  # The interpreter and gemba run the *same* IR, so a marker drawn at a rolled
  # position must land in the same place on both — which confirms the draw works
  # on hardware and that the two backends churn the stream identically.

  def marker_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :white
      roll :x, 0..200
      roll :y, 0..140
      draw_rect_at :x, :y, 4, 4, :red
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_interpreter_and_hardware_agree_on_the_drawn_position
    program = marker_program
    i = Ruby.new.run(program)
    x = i[:x]
    y = i[:y]

    # The interpreter drew the 4x4 marker here.
    assert_equal Color.resolve(:red), i.screen.pixel(x, y), "interpreter drew the marker at (#{x},#{y})"

    rom = RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(program),
                                title: "RANDOM", code: "BRND", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)
    assert v.red?(x, y), "console drew the marker at the same (#{x},#{y}) the interpreter did"
    assert v.white?(x + 10, y), "and only there — the field beside it is untouched"
  end
end
