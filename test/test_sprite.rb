# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The `sprite` helper: a named image that moves around leaving no trail, repainted
# by the framework each frame. These assert BEHAVIOR on both backends — the sprite
# appears, moves without smearing, and hides/shows cleanly — the interpreter as the
# oracle, gemba for the console.
#
# The no-trail invariant is asserted crisply by counting: a sprite of a solid block
# should colour exactly one block's worth of pixels no matter how far it has moved.
# A trail would leave more. Each program ends with `after(N) { halt }` so the run
# stops on a settled frame (right after a completed repaint), making the count exact.
class TestSprite < Minitest::Test
  include GembaSupport
  include RubyGBA::Constants

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  BLOCK = 4           # a 4x4 solid-red sprite
  FIELD = :blue       # the field it moves over
  START = [100, 60].freeze

  # Build a sprite program: a blue field cleared once, a red block sprite, the given
  # loop body, and a halt after `frames` so the screen is read on a settled frame.
  def sprite_program(frames:, &body)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { "####\n####\n####\n####" }
      clear_screen FIELD
      hero = sprite :block, at: START
      game_loop do
        wait_vblank
        after(frames) { halt }
        instance_exec(hero, &body) if body
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def count_color(screen, color)
    want = Color.resolve(color)
    n = 0
    240.times { |x| 160.times { |y| n += 1 if screen.pixel(x, y) == want } }
    n
  end

  # ---- it appears at its start ----

  def test_a_sprite_shows_up_at_its_start_position
    screen = Ruby.new.run(sprite_program(frames: 3)).screen
    (0...BLOCK).each do |dy|
      (0...BLOCK).each do |dx|
        assert_equal Color.resolve(:red), screen.pixel(START[0] + dx, START[1] + dy),
                     "sprite pixel (#{dx},#{dy}) missing at start"
      end
    end
    assert_equal BLOCK * BLOCK, count_color(screen, :red), "more than one block of red at rest — a trail?"
  end

  # ---- it restores patterned scenery pixel-for-pixel as it passes ----

  # A red band with a distinct blue detail set into it, in the sprite's path. After
  # the sprite has driven across the detail, every pixel it passed over must be
  # exactly as it was — the blue detail intact, the red band unbroken around it.
  def scenery_program(frames:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image(:block, "#" => :white) { "####\n####\n####\n####" }
      fill_rect 0, 40, 240, 16, :red    # a red band
      fill_rect 30, 44, 4, 4, :blue     # a blue detail inside it, in the path
      hero = sprite :block, at: [8, 44]
      game_loop do
        wait_vblank
        after(frames) { halt }
        hero.x.add 2                     # drive right, across the blue detail
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_sprite_restores_patterned_scenery_it_passes_over
    screen = Ruby.new.run(scenery_program(frames: 25)).screen # ends near x=58, past the detail
    # the blue detail the sprite drove across is intact
    (30...34).each do |x|
      (44...48).each { |y| assert_equal Color.resolve(:blue), screen.pixel(x, y), "blue detail torn at (#{x},#{y})" }
    end
    # the red band around it is unbroken where the sprite passed
    (10...28).each { |x| assert_equal Color.resolve(:red), screen.pixel(x, 46), "red band torn at x=#{x}" }
    assert_equal BLOCK * BLOCK, count_color(screen, :white), "the sprite left a trail across the scenery"
  end

  def test_it_restores_patterned_scenery_on_gemba
    rom = ROM.assemble(GBA.new.lower(scenery_program(frames: 25)), title: "SPRSCEN", code: "BSPS", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 26)
    assert v.pixel_is?(31, 45, :blue), "blue detail not restored on hardware — got #{v.pixel_gba(31, 45).to_s(16)}"
    assert v.red?(15, 46), "red band not restored on hardware"
  end

  # ---- it moves, and leaves no trail ----

  def test_moving_the_sprite_leaves_no_trail
    prog = sprite_program(frames: 20) { |hero| hero.x.add 2 } # drift right every frame
    screen = Ruby.new.run(prog).screen

    # exactly one block of red survives, wherever it ended up — no smear
    assert_equal BLOCK * BLOCK, count_color(screen, :red), "a trail of red was left behind"
    # it actually moved: the start cells are field-coloured again
    assert_equal Color.resolve(FIELD), screen.pixel(START[0] + 1, START[1] + 1), "the start cell wasn't restored"
    # and the block sits to the right of where it began
    moved = (0...240).any? { |x| x > START[0] + BLOCK && (0...160).any? { |y| screen.pixel(x, y) == Color.resolve(:red) } }
    assert moved, "the sprite didn't move right"
  end

  def test_steering_with_held_input_moves_the_sprite
    prog = sprite_program(frames: 15) { |hero| held(:right).then { hero.x.add 2 } }
    i = Ruby.new.input_each_frame { |_f| [:right] }.run(prog)
    assert_operator i[:__spr1_x], :>, START[0], "holding right didn't move the sprite"
    assert_equal BLOCK * BLOCK, count_color(i.screen, :red), "held-move left a trail"
  end

  # ---- directional move: say it the way the player thinks it ----

  def test_move_by_direction_steps_the_right_way
    # Press left then up-right; the sprite should end up moved accordingly, in pixels.
    prog = sprite_program(frames: 4) do |hero|
      after(1) { hero.move :left, by: 3 }      # x: 100 -> 97
      after(2) { hero.move :up_right, by: 2 }  # x: 97 -> 99, y: 60 -> 58
    end
    i = Ruby.new.run(prog)
    assert_equal 99, i[:__spr1_x], "left then up_right didn't land x where expected"
    assert_equal 58, i[:__spr1_y], "up_right didn't move y up"
    assert_equal BLOCK * BLOCK, count_color(i.screen, :red), "a directional move left a trail"
  end

  def test_an_unknown_direction_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image(:b, "#" => :red) { "##\n##" }
        sprite(:b, at: [0, 0]).move(:sideways)
      end
    end
    assert_match(/sideways/, err.message)
    assert_match(/direction/, err.message)
  end

  # ---- hide restores the background; show brings it back ----

  def test_hide_removes_the_sprite_and_show_brings_it_back
    hidden = Ruby.new.input_each_frame { |f| f >= 2 ? [:a] : [] }
                 .run(sprite_program(frames: 6) { |hero| pressed(:a).then { hero.hide } }).screen
    assert_equal 0, count_color(hidden, :red), "hide left the sprite on screen"
    assert_equal Color.resolve(FIELD), hidden.pixel(START[0] + 1, START[1] + 1), "hide didn't restore the field"

    shown = Ruby.new.input_each_frame { |f| f == 2 ? [:a] : (f == 4 ? [:b] : []) }
                .run(sprite_program(frames: 8) do |hero|
                  pressed(:a).then { hero.hide }
                  pressed(:b).then { hero.show }
                end).screen
    assert_equal BLOCK * BLOCK, count_color(shown, :red), "show didn't bring the sprite back"
  end

  # ---- a sprite that arrives late (a boss): reserved up front, shown on cue ----

  # A boss declared shown: false, revealed on `show_on`, with the run halted on
  # `halt_on` so the screen is read at a known frame.
  def boss_program(show_on:, halt_on:)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      image(:boss, "#" => :red) { "####\n####\n####\n####" }
      clear_screen FIELD
      boss = sprite :boss, at: [50, 50], shown: false
      game_loop do
        wait_vblank
        after(show_on) { boss.show }
        after(halt_on) { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_hidden_sprite_stays_dark_until_it_is_shown
    # Halt before the reveal: the boss (its RAM reserved all along) has drawn nothing.
    before = Ruby.new.run(boss_program(show_on: 5, halt_on: 3)).screen
    assert_equal 0, count_color(before, :red), "a hidden sprite drew before it was shown"

    # Reveal on frame 3, halt on 6: the boss has appeared at its declared spot.
    after_show = Ruby.new.run(boss_program(show_on: 3, halt_on: 6)).screen
    assert_equal BLOCK * BLOCK, count_color(after_show, :red), "the boss didn't appear after show"
    assert_equal Color.resolve(:red), after_show.pixel(52, 52), "the boss isn't at its declared spot"
  end

  # ---- misuse ----

  def test_a_sprite_of_an_undefined_image_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        sprite :ghost, at: [0, 0]
      end
    end
    assert_match(/ghost/, err.message)
    assert_match(/image/, err.message)
  end

  # ---- hardware: it renders and moves on the console ----

  def test_the_sprite_renders_and_moves_on_gemba
    prog = sprite_program(frames: 30) { |hero| held(:right).then { hero.x.add 2 } }
    rom = ROM.assemble(GBA.new.lower(prog), title: "SPRITETS", code: "BSPT", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 12, keys: KEY_RIGHT)
    # it moved off its start (that cell is field again) and shows red further right
    assert v.blue?(START[0] + 1, START[1] + 1), "start cell not restored on hardware"
    moved = (START[0] + BLOCK..200).any? { |x| v.pixel_is?(x, START[1] + 1, :red) }
    assert moved, "sprite not found to the right on hardware"
  end
end
