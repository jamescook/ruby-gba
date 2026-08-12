# frozen_string_literal: true

require "test_helper"
require "differential"

# `tint` — moving the whole picture toward a color, which is `fade`'s sibling and not a
# fade with a color argument. A fade changes BRIGHTNESS (a display can do that to a
# finished picture); a tint mixes a color IN. They reach the screen by different means
# and round differently, so the numbers below are asserted rather than derived.
class TestTint < Minitest::Test
  include Differential

  # A green screen and one tint, as the DSL writes it.
  def tinted(color, amount, screen_kind: :bitmap, tear_free: false)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen screen_kind, tear_free: tear_free
      clear_screen :green
      tint color, amount
      halt
    end
    b.emit_pending_functions
    b.program
  end

  def shown(program)
    Reference.new.run(program).screen.pixel(120, 80)
  end

  GREEN = 0x03E0
  RED = 0x001F

  # --- what a tint looks like ---

  def test_no_amount_leaves_the_picture_as_drawn
    assert_equal GREEN, shown(tinted(:red, 0))
  end

  def test_a_full_tint_leaves_nothing_but_the_color
    assert_equal RED, shown(tinted(:red, 100))
  end

  # Half way is NOT "half of each channel rounded once". The display takes each side's
  # share separately and truncates each before adding, which is why this is 0x01ef and
  # not something a simpler formula would give.
  def test_half_way_mixes_the_two_a_channel_at_a_time
    assert_equal 0x01EF, shown(tinted(:red, 50))
  end

  def test_the_amount_walks_the_picture_toward_the_color
    seen = [0, 25, 50, 75, 100].map { |amount| shown(tinted(:red, amount)) }

    assert_equal [GREEN, 0x02E7, 0x01EF, 0x00F7, RED], seen
  end

  # The picture is not redrawn, so it is all still there when the tint lifts. Written as
  # two tints in one program, because that is how a game brings one back.
  def test_the_picture_comes_back_untouched
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.emit_pending_functions

    assert_equal GREEN, shown(b.program)
  end

  # A tint the game works out, rather than one written into the program — the form an
  # effect walked over frames needs.
  def test_an_amount_the_game_works_out
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      level.set 50
      tint :red, level
      halt
    end
    b.emit_pending_functions

    assert_equal 0x01EF, shown(b.program)
  end

  # --- the console agrees, which is the point of having two backends ---

  def test_the_console_shows_the_same_colors
    [0, 25, 50, 75, 100].each do |amount|
      program = tinted(:red, amount)
      rom = assemble_rom(program, name: "TINT")
      console = assert_gemba_loads_rom(rom, frames: 6).pixel_gba(120, 80)

      assert_equal shown(program), console,
                   "at #{amount}% the two backends disagree"
    end
  end

  # The whole screen, not the five pixels above. `blended:` allows the emulator its
  # coarser blend (see Differential::EMULATOR_BLEND_SLACK); the exact arithmetic is what
  # the per-color assertions above pin.
  def test_the_console_agrees_over_the_whole_screen
    assert_backends_agree(tinted(:red, 50), frames: 2, blended: true)
  end

  # A tint the game works out is converted as the program runs, which is a different
  # path through the lowering than a number written into it.
  def test_the_console_agrees_on_an_amount_the_game_works_out
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop do
        level.set 50
        tint :red, level
      end
    end
    b.emit_pending_functions
    program = b.program

    oracle = Reference.new.run(program, frames: 2).screen.pixel(120, 80)
    console = assert_gemba_loads_rom(assemble_rom(program, name: "TINTV"), frames: 6).pixel_gba(120, 80)

    assert_equal 0x01EF, oracle
    assert_equal oracle, console
  end

  # --- a tint and a fade are one effect on the display ---
  #
  # There is one blend on the console and both verbs drive it, so the last one set is
  # the one in force. Modelled rather than hidden: a program cannot look right on one
  # backend and wrong on the other.

  def test_a_tint_after_a_fade_replaces_it
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      fade :black, 100
      tint :red, 100
      halt
    end
    b.emit_pending_functions

    assert_equal RED, shown(b.program)
  end

  def test_a_fade_after_a_tint_replaces_it
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      fade :black, 100
      halt
    end
    b.emit_pending_functions

    assert_equal 0x0000, shown(b.program)
  end

  # --- what it refuses, and why ---

  def test_a_tiled_screen_is_refused_and_says_which_screen_works
    error = assert_raises(ArgumentError) { tinted(:red, 50, screen_kind: :tiled) }

    assert_includes error.message, "screen :tiled"
    assert_includes error.message, "screen :bitmap"
  end

  def test_the_buffered_screen_is_refused_by_name
    error = assert_raises(ArgumentError) { tinted(:red, 50, tear_free: true) }

    assert_includes error.message, "tear_free: true"
  end

  # A scene that declares its own screen is judged on ITS screen, not the program's.
  def test_a_tiled_scene_inside_a_bitmap_program_is_refused
    b = RubyGBA::Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        scene(:play) do
          screen :tiled
          tint :red, 50
        end
        game_loop { call :_scene_play }
      end
      b.emit_pending_functions
    end

    assert_includes error.message, "screen :tiled"
  end

  def test_an_amount_out_of_range_says_the_range
    error = assert_raises(ArgumentError) { tinted(:red, 140) }

    assert_includes error.message, "0 to 100"
  end

  def test_an_unknown_color_is_refused
    assert_raises(ArgumentError) { tinted(:reddish, 50) }
  end

  # --- the guardrail ---

  def warnings(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_full_tint_never_lifted_is_a_warning
    assert_includes warnings(tinted(:red, 100)), :tint_never_lifted
  end

  def test_a_tint_that_is_lifted_says_nothing
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_partial_tint_is_a_style_choice_not_a_bug
    refute_includes warnings(tinted(:red, 60)), :tint_never_lifted
  end

  # A tint over time is written with a variable, and where it ends up is not knowable
  # while building — so those programs are left alone rather than warned at.
  def test_a_tint_the_game_works_out_is_left_alone
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop { level.approach 100, 4; tint :red, level }
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_program_with_no_tint_says_nothing
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      halt
    end
    b.emit_pending_functions

    refute_includes warnings(b.program), :tint_never_lifted
  end

  # --- what it costs ---
  #
  # A tint tells the display what to show and redraws nothing, so its price must not
  # depend on what is on screen — the same promise `fade` makes.

  def cost_of(program)
    RubyGBA::IR::CostModel.new.steady_cost(program)
  end

  # What a tint adds to a frame must not depend on what else that frame draws. Measured
  # as a difference twice over — the same tint added to an empty frame and to a busy one
  # — so a price that quietly scaled with the drawing would show up here.
  def test_a_tint_costs_the_same_however_much_is_on_screen
    empty = cost_of(loop_body { |_g| nil })
    empty_tinted = cost_of(loop_body { |g| g.tint :red, 50 })
    busy = cost_of(loop_body { |g| draw_a_lot(g) })
    busy_tinted = cost_of(loop_body { |g| draw_a_lot(g); g.tint :red, 50 })

    assert_operator busy, :>, empty, "the drawing itself must still cost"
    assert_in_delta empty_tinted - empty, busy_tinted - busy, 1e-9
  end

  def test_a_tint_is_priced_at_something
    assert_operator cost_of(loop_body { |g| g.tint :red, 50 }),
                    :>, cost_of(loop_body { |_g| nil })
  end

  def draw_a_lot(builder)
    40.times { |i| builder.fill_rect 0, i, 40, 1, :blue }
  end

  # The builder is handed to the body rather than the body being instance_eval'd, because
  # a block written here keeps this test as its `self` (see Builder#run_block).
  def loop_body(&body)
    b = RubyGBA::Builder.new
    b.instance_eval { screen :bitmap }
    b.game_loop { body.call(b) }
    b.emit_pending_functions
    b.program
  end

  # An amount the game works out costs more than one written into the program: the
  # conversion happens as the program runs.
  def test_a_computed_amount_costs_more_than_a_written_one
    written = RubyGBA::Builder.new
    written.instance_eval do
      screen :bitmap
      game_loop { tint :red, 50 }
    end
    written.emit_pending_functions

    computed = RubyGBA::Builder.new
    computed.instance_eval do
      screen :bitmap
      level = var :level, 50
      game_loop { tint :red, level }
    end
    computed.emit_pending_functions

    assert_operator cost_of(computed.program), :>, cost_of(written.program)
  end
end

