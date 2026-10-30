# frozen_string_literal: true

require "test_helper"
require "differential"

# The games these tests play, shared with the Advance cartridge's own tests of the same tints
# (test/lowering/gba/vblank/builder/test_tint_cartridge.rb).
module TintGames
  include SharedConstants

  GREEN = 0x03E0
  RED = 0x001F

  # A green screen and one tint, as the DSL writes it.
  private def tinted(color, amount, screen_kind: :bitmap, tear_free: false, under: :green)
    b = VBlank::Builder.new
    b.instance_eval do
      screen screen_kind, tear_free: tear_free
      clear_screen under
      tint color, amount
      halt
    end
    b.finalize_program
    b.program
  end

  private def shown(program)
    game_player.run(program).screen.pixel(120, 80)
  end

  # A tint the game works out, set on every pass of the loop. It is converted as the program
  # runs, which is a different path through the lowering than a number written into it.
  private def worked_out_tint
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop do
        level.set! 50
        tint :red, level
      end
    end
    b.finalize_program
    b.program
  end

  # A green screen and one tint on the tear-free screen. Its colors are drawn from a
  # table, so this exercises the other mechanism entirely.
  private def buffered_tint(color, amount)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :green
        tint color, amount
      end
    end
    b.finalize_program
    b.program
  end

  # A tiled screen: one solid background under one sprite, in different colors. The
  # scenery and the sprite draw from two different tables and BOTH have to move, which
  # is the thing the table mechanism buys over every other way of doing this.
  private def tiled_tint(amount, extra_frames: 0)
    tile = SOLID_TILE
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:ground, "#" => :green) { tile }
      image(:body, "#" => :white) { tile }
      tiles :grass, "#" => :ground
      background :field, tiles: :grass, map: Array.new(20) { "#" * 30 }
      sprite :body, at: [64, 64]
      level = var :level, 0
      game_loop do
        level.set! amount
        tint :red, level
      end
    end
    b.finalize_program
    b.program
  end

  # (64, 64) is the sprite's top-left corner; (8, 8) is scenery well clear of it.
  SPRITE_XY = [66, 66].freeze
  SCENERY_XY = [8, 8].freeze

  WHITE = 0x7FFF

  # The green scenery and the white sprite, each at 0%, 50% and 100% of the way to red.
  # Named here rather than derived so a lowering that quietly changed the arithmetic on
  # one screen could not move both sides of the comparison below with it.
  TILED_SCENERY = [GREEN, 0x01EF, RED].freeze
  TILED_SPRITE = [WHITE, 0x3DFF, RED].freeze
  TILED_AMOUNTS = [0, 50, 100].freeze

  # An amount the game works out on the tear-free screen — the steps are worked out as the
  # program runs, and so is the color's share of every entry.
  private def worked_out_buffered_tint
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      level = var :level, 0
      game_loop do
        clear_screen :green
        level.set! 50
        tint :red, level
      end
    end
    b.finalize_program
    b.program
  end

  # A full tint and then a fade of nothing, every pass, on the tear-free screen.
  private def buffered_tint_then_fade
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :green
        tint :red, 100
        fade :white, 0
      end
    end
    b.finalize_program
    b.program
  end

  # A game whose scenes cross the two display systems puts a DIFFERENT color table in the
  # same place on each switch, so a tint remembered from before the crossing describes a
  # table that is no longer there. Here a tear-free scene tints itself fully red, hands
  # over to a tiled scene, and comes back with the tint lifted — and the picture has to be
  # the green it was drawn as, not the red left in a table nobody put back.
  private def crossing_program
    tile = SOLID_TILE
    b = VBlank::Builder.new
    b.instance_eval do
      image(:dot, "#" => :white) { tile }
      screen :bitmap, tear_free: true
      state = var :state, 0
      level = var :level, 100
      frames = var :frames, 0
      scene :field do
        clear_screen :green
        tint :red, level
      end
      scene :away do
        screen :tiled
        sprite :dot, at: [200, 140]
      end
      game_loop do
        frames.add! 1
        state.set! 0
        (frames > 2).then { state.set! 1 }
        (frames > 5).then { state.set! 0; level.set! 0 }
        case_var :state do
          when_val 0, :field
          when_val 1, :away
        end
      end
    end
    b.finalize_program
    b.program
  end
end

# `tint` — moving the whole picture toward a color, which is `fade`'s sibling and not a
# fade with a color argument. A fade changes BRIGHTNESS (a display can do that to a
# finished picture); a tint mixes a color IN. They reach the screen by different means
# and round differently, so the numbers below are asserted rather than derived.
#
# The Advance's cartridge read in the emulator, and what a tint costs it, are in
# test/lowering/gba/vblank/builder/test_tint_cartridge.rb.
class TestTint < Minitest::Test
  include Differential
  include TintGames

  # --- what a tint looks like ---

  def test_no_amount_leaves_the_picture_as_drawn
    assert_equal GREEN, shown(tinted(:red, 0))
  end

  def test_a_full_tint_leaves_nothing_but_the_color
    assert_equal RED, shown(tinted(:red, 100))
  end

  # Half way, a channel at the top and one at nothing meet at 15, not 16: the fraction is
  # dropped, so green loses its half step and red does not gain one.
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
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.finalize_program

    assert_equal GREEN, shown(b.program)
  end

  # A tint the game works out, rather than one written into the program — the form an
  # effect walked over frames needs.
  def test_an_amount_the_game_works_out
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      level.set! 50
      tint :red, level
      halt
    end
    b.finalize_program

    assert_equal 0x01EF, shown(b.program)
  end

  # --- the console agrees, which is the point of having two backends ---

  # The whole screen, not the five pixels above.
  def test_the_console_agrees_over_the_whole_screen
    assert_backends_agree(tinted(:red, 50), frames: 2)
  end

  # A gray of 16 in every channel, for tints over a grey screen (how the Advance's display
  # mixes one is tested in test_tint_on_the_advance.rb).
  MID_GRAY = 16 | (16 << 5) | (16 << 10)

  # MID_GRAY tinted half way to yellow, painted on every frame: the tear-free screen keeps
  # two pictures and shows them in turn, so one painted once would show only half the time.
  private def gray_redrawn_under_yellow
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      tint :yellow, 50
      game_loop { clear_screen MID_GRAY }
    end
    b.finalize_program
    b.program
  end

  # ...and on a tiled screen, which has no picture to clear: a background of gray tiles.
  private def gray_tiles_under_yellow
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:gray, "#" => MID_GRAY) { "########\n" * 8 }
      tiles :grays, "#" => :gray
      background :floor, tiles: :grays, map: Array.new(20) { "#" * 30 }
      tint :yellow, 50
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  # The same tint on a screen drawn through a color table is the game's own work: it
  # writes the tinted colors into the table in five bits, and the display shows them as
  # they are. So there red and green stop a step short, at 23.
  def test_a_tint_on_a_color_table_is_mixed_at_five_bits
    { tear_free: gray_redrawn_under_yellow, tiled: gray_tiles_under_yellow }.each do |kind, program|
      assert_backends_agree(program, frames: 2, name: "TABLE")
      assert_equal 23 | (23 << 5) | (8 << 10), shown(program), "on the #{kind} screen"
    end
  end

  # A tint the game works out is converted as the program runs, which is a different
  # path through the lowering than a number written into it.
  def test_the_console_agrees_on_an_amount_the_game_works_out
    assert_equal 0x01EF, game_player.run(worked_out_tint, frames: 2).screen.pixel(120, 80)
  end

  # --- a tint and a fade are one effect on the display ---
  #
  # There is one blend on the console and both verbs drive it, so the last one set is
  # the one in force. Modelled rather than hidden: a program cannot look right on one
  # backend and wrong on the other.

  def test_a_tint_after_a_fade_replaces_it
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      fade :black, 100
      tint :red, 100
      halt
    end
    b.finalize_program

    assert_equal RED, shown(b.program)
  end

  def test_a_fade_after_a_tint_replaces_it
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      fade :black, 100
      halt
    end
    b.finalize_program

    assert_equal 0x0000, shown(b.program)
  end

  # --- the screens that draw through a color table ---
  #
  # The tear-free bitmap screen and the tiled screen don't hold a color in every pixel:
  # a pixel is a number that picks a color out of a shared table. The display's own
  # blend cannot tint them (the color it would blend against is the table's own first
  # entry — see Backends::GBA::PaletteTint), so the framework moves the table instead.
  # The author writes the same `tint`; these pin that the picture comes out the same.

  def test_the_tear_free_screen_walks_the_picture_toward_the_color
    seen = [0, 25, 50, 75, 100].map { |amount| shown(buffered_tint(:red, amount)) }

    assert_equal [GREEN, 0x02E7, 0x01EF, 0x00F7, RED], seen
  end

  def test_a_tiled_screen_tints_the_scenery_and_the_sprites_together
    seen = TILED_AMOUNTS.map do |amount|
      screen = game_player.run(tiled_tint(amount), frames: 2).screen
      [screen.pixel(*SCENERY_XY), screen.pixel(*SPRITE_XY)]
    end

    assert_equal TILED_SCENERY, seen.map(&:first)
    assert_equal TILED_SPRITE, seen.map(&:last)
  end

  # An amount the game works out takes the other path through the lowering — the steps
  # are worked out as the program runs, and so is the color's share of every entry.
  def test_the_console_agrees_on_a_worked_out_amount_on_the_tear_free_screen
    assert_equal 0x01EF, game_player.run(worked_out_buffered_tint, frames: 2).screen.pixel(120, 80)
  end

  # On this screen the fade and the tint are separate pieces of hardware, so nothing
  # puts a tint away by itself. The display still shows one whole-picture effect at a
  # time — the rule the DSL states — so the fade has to put the colors back, and the
  # console must land where the interpreter says.
  def test_a_fade_after_a_tint_replaces_it_on_the_tear_free_screen
    assert_equal GREEN, shown(buffered_tint_then_fade)
  end

  def test_a_tint_does_not_survive_a_trip_through_the_other_display
    assert_equal GREEN, game_player.run(crossing_program, frames: 10).screen.pixel(120, 80)
  end

  # --- what it refuses, and why ---

  def test_an_amount_out_of_range_says_the_range
    error = assert_raises(ArgumentError) { tinted(:red, 140) }

    assert_includes error.message, "0 to 100"
  end

  def test_an_unknown_color_is_refused
    assert_raises(ArgumentError) { tinted(:reddish, 50) }
  end

  # --- the guardrail ---

  private def warnings(program)
    VBlank::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_full_tint_never_lifted_is_a_warning
    assert_includes warnings(tinted(:red, 100)), :tint_never_lifted
  end

  def test_a_tint_that_is_lifted_says_nothing
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      tint :red, 100
      tint :red, 0
      halt
    end
    b.finalize_program

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_partial_tint_is_a_style_choice_not_a_bug
    refute_includes warnings(tinted(:red, 60)), :tint_never_lifted
  end

  # A tint over time is written with a variable, and where it ends up is not knowable
  # while building — so those programs are left alone rather than warned at.
  def test_a_tint_the_game_works_out_is_left_alone
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      level = var :level, 0
      game_loop { level.approach! 100, 4; tint :red, level }
    end
    b.finalize_program

    refute_includes warnings(b.program), :tint_never_lifted
  end

  def test_a_program_with_no_tint_says_nothing
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      halt
    end
    b.finalize_program

    refute_includes warnings(b.program), :tint_never_lifted
  end
end
