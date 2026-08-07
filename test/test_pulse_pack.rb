# frozen_string_literal: true

require "test_helper"

# The `pulse` effect pack: a sprite that grows, shrinks and keeps doing it. These assert
# what a player sees — the sprite is bigger part-way through the cycle than it started,
# back near its starting size by the end of it, and off again after that — plus the
# friendly errors. The pack is written entirely in public DSL verbs on top of
# `sprite.scale`, so it needs no backend of its own; that it runs on the oracle at all is
# the evidence for that.
class TestPulsePack < Minitest::Test
  BLOCK = (["#" * 16] * 16).join("\n")

  # One second, so half a cycle is 30 frames and the numbers below are easy to place.
  SECONDS = 1.0
  HALF = 30

  # A pulse from its own size up to half again, run for +frames+ frames.
  def pulse_program(frames, to: 1.5, from: 1.0, over: SECONDS)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      block = sprite :block, at: [100, 60]
      pulse block, from: from, to: to, over: over
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # The sprite's size after +frames+ frames, as the multiple the author writes.
  def size_after(frames, **opts)
    interpreter = Reference.new.run(pulse_program(frames, **opts), max_steps: 50_000_000)
    interpreter[:__obj1_scale] / RubyGBA::IR::Build::SCALE_ONE.to_f
  end

  # --- it breathes ---

  # Part-way up the climb the sprite is bigger than it started but not yet at the top.
  def test_it_is_part_way_grown_part_way_through_the_climb
    size = size_after(HALF / 2)
    assert_operator size, :>, 1.1
    assert_operator size, :<, 1.5
  end

  # It reaches the size that was asked for, rather than stopping a little short.
  def test_it_reaches_the_size_it_was_asked_for
    assert_in_delta 1.5, size_after(HALF - 1), 0.01
  end

  # ...and comes back down. By the end of the cycle it is near where it began.
  def test_it_shrinks_back_by_the_end_of_the_cycle
    assert_in_delta 1.0, size_after(HALF * 2), 0.05
  end

  # And then goes again — a pulse repeats rather than running once.
  def test_it_goes_again_on_the_next_cycle
    assert_in_delta size_after(HALF / 2), size_after((HALF * 2) + (HALF / 2)), 0.05
  end

  # A pulse can breathe around a size, not only up from one.
  def test_it_can_start_smaller_than_the_drawn_size
    assert_in_delta 0.8, size_after(1, from: 0.8, to: 1.2), 0.02
    assert_operator size_after(HALF - 1, from: 0.8, to: 1.2), :>, 1.1
  end

  # --- friendly guardrails ---

  def test_a_pulse_to_a_size_of_zero_is_a_friendly_error
    err = assert_raises(ArgumentError) { pulse_program(2, to: 0) }
    assert_match(/more than 0/, err.message)
  end

  def test_a_pulse_between_one_size_and_itself_is_a_friendly_error
    err = assert_raises(ArgumentError) { pulse_program(2, from: 1.2, to: 1.2) }
    assert_match(/different sizes/, err.message)
  end

  def test_a_pulse_over_no_time_is_a_friendly_error
    err = assert_raises(ArgumentError) { pulse_program(2, over: 0) }
    assert_match(/positive number of seconds/, err.message)
  end

  # A pulse only exists over time, so with no game loop there are no frames to run it on
  # and the sprite sits perfectly still. Silent, and the call looks right where it is
  # written — so the build says so.
  def test_a_pulse_with_no_game_loop_is_a_friendly_warning
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      pulse sprite(:block, at: [100, 60]), to: 1.5
      halt
    end
    builder.emit_pending_functions

    findings = RubyGBA::IR::Guardrails::Validator.new.run(builder.program, autofix: false).findings
    pulse_finding = findings.find { |finding| finding.check == :pulse_needs_game_loop }
    refute_nil pulse_finding, "expected the no-game-loop warning, got #{findings.map(&:check).inspect}"
    assert_match(/game_loop/, pulse_finding.message)
  end

  # A bitmap sprite cannot resize at all, so the pulse fails where the author wrote it
  # with the error `scale` already gives — the pack adds no second explanation.
  def test_a_pulse_on_a_bitmap_sprite_is_a_friendly_error
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        image(:hero, "#" => :red) { (["########"] * 8).join("\n") }
        clear_screen :black
        pulse sprite(:hero, at: [10, 10]), to: 1.5
      end
    end
    assert_match(/screen :tiled/, err.message)
  end

  # --- it is a pack, not a feature ---

  # Pulsing the same sprite twice replaces the rhythm rather than running two that fight
  # over the size. One routine, whatever the game does.
  def test_pulsing_a_sprite_twice_leaves_one_rhythm
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      block = sprite :block, at: [100, 60]
      pulse block, to: 1.5
      pulse block, to: 1.2, over: 0.5
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions

    routines = builder.program.walk.select { |node| node[:name].to_s.start_with?("__pulse___obj1") }
                      .select { |node| node.kind == :func }
    assert_equal 1, routines.length, "expected one pulse routine, got #{routines.map { |r| r[:name] }.inspect}"
  end

  # The pack is registered like any other verb, so a game writes `pulse` next to
  # `fill_rect` and cannot tell which is a framework verb and which is a pack's.
  def test_pulse_is_a_registered_pack_verb
    assert_equal RubyGBA::Effects::Packs::Pulse, RubyGBA::Effects.verbs[:pulse]
  end
end
