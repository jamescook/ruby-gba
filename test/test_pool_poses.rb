# frozen_string_literal: true

require "test_helper"

# A POOLED THING FACES AND ANIMATES, each instance on its own.
#
# A pool given `image:` draws every live instance as a hardware sprite, which is one line for
# a game with a cast. Every instance used to be stuck on the picture it was declared with, so
# ten enemies were ten identical statues and a game that wanted them to walk had to declare ten
# sprites by hand and keep their state in parallel lists — the exact thing `pool` exists to
# prevent.
#
# So `facing:` and `frames:` mean on a pool what they already mean on a sprite, spelled the same
# way, and `face` is the same verb on the row handle. What is new underneath is that the
# direction and the place in the cycle are PER INSTANCE: a hidden slot beside the fields, the
# pool's own bookkeeping rather than something to declare.
class TestPoolPoses < Minitest::Test
  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)
  GREEN = Color.resolve(:green)
  YELLOW = Color.resolve(:yellow)
  BLACK = 0

  def solid(color)
    { "#" => color }
  end

  # A tiled program with four 8x8 pictures and a pool the block sets up.
  def pool_program(**pool_opts)
    b = Builder.new
    handle = nil
    b.instance_eval do
      screen :tiled
      image(:left1, "#" => :red) { "########\n" * 8 }
      image(:left2, "#" => :blue) { "########\n" * 8 }
      image(:right1, "#" => :green) { "########\n" * 8 }
      image(:right2, "#" => :yellow) { "########\n" * 8 }
      handle = pool :guard, x: 0, y: 0, capacity: 8, **pool_opts
      yield(self, handle)
    end
    b.emit_pending_functions
    b.program
  end

  # --- facing, per instance ---

  def test_two_instances_face_two_ways
    prog = pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
      guards.spawn x: 20, y: 20
      guards.spawn x: 60, y: 20
      b.game_loop do
        b.wait_vblank
        guards.each { |g| (g.x == 20).then { g.face :left }.else { g.face :right } }
      end
    end

    screen = Reference.new.run(prog).screen
    assert_equal RED, screen.pixel(22, 22), "the one at 20 faces left"
    assert_equal GREEN, screen.pixel(62, 22), "the one at 60 faces right, in the same frame"
  end

  def test_an_instance_starts_facing_the_first_direction
    prog = pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
      guards.spawn x: 20, y: 20
      b.game_loop { b.wait_vblank }
    end

    assert_equal RED, Reference.new.run(prog).screen.pixel(22, 22),
                 "an instance nobody has turned faces the first direction given"
  end

  # A slot reused by a later spawn must not still be facing whatever the last instance in it
  # was facing — which is the bug a per-slot field invites and the reason spawn resets it.
  def test_a_reused_slot_starts_facing_the_first_direction_again
    prog = pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
      guards.spawn x: 20, y: 20
      turned = b.var :turned, 0
      b.game_loop do
        b.wait_vblank
        (turned == 0).then do
          guards.each { |g| g.face :right; g.remove }
          guards.spawn x: 20, y: 20
          turned.set 1
        end
      end
    end

    assert_equal RED, Reference.new.run(prog).screen.pixel(22, 22),
                 "the new instance faces left, not the right the old one was turned to"
  end

  # --- animating ---

  def test_a_pooled_instance_cycles_its_frames
    prog = pool_program(frames: %i[left1 left2], rate: 2) do |b, guards|
      guards.spawn x: 20, y: 20
      b.game_loop { b.wait_vblank }
    end

    # Two pictures at a rate of two: each is shown for two frames, then the cycle wraps.
    assert_equal RED, Reference.new.run(prog, frames: 2).screen.pixel(22, 22)
    assert_equal BLUE, Reference.new.run(prog, frames: 3).screen.pixel(22, 22)
    assert_equal RED, Reference.new.run(prog, frames: 5).screen.pixel(22, 22), "and it wraps"
  end

  # The one that decides whether the composition layer is usable for a cast: a walk cycle
  # per direction, chosen per instance.
  def test_two_instances_walk_in_two_directions_at_once
    prog = pool_program(facing: { left: %i[left1 left2], right: %i[right1 right2] },
                        rate: 2) do |b, guards|
      guards.spawn x: 20, y: 20
      guards.spawn x: 60, y: 20
      b.game_loop do
        b.wait_vblank
        guards.each { |g| (g.x == 20).then { g.face :left }.else { g.face :right } }
      end
    end

    early = Reference.new.run(prog, frames: 2).screen
    assert_equal RED, early.pixel(22, 22), "the left one is on its first frame"
    assert_equal GREEN, early.pixel(62, 22), "the right one is on its own first frame"

    later = Reference.new.run(prog, frames: 3).screen
    assert_equal BLUE, later.pixel(22, 22), "the left one stepped to its second frame"
    assert_equal YELLOW, later.pixel(62, 22), "and the right one to its own"
  end

  # Instances spawned at different moments sit at different points in the same cycle, which
  # is what stops a pool of them pulsing as one.
  def test_instances_spawned_at_different_moments_are_out_of_step
    prog = pool_program(frames: %i[left1 left2 right1 right2], rate: 1) do |b, guards|
      guards.spawn x: 20, y: 20
      later = b.var :later, 0
      b.game_loop do
        b.wait_vblank
        later.add 1
        (later == 2).then { guards.spawn x: 60, y: 20 }
      end
    end

    screen = Reference.new.run(prog, frames: 5).screen
    refute_equal screen.pixel(22, 22), screen.pixel(62, 22),
                 "the one spawned later is at a different point in the cycle"
  end

  # --- the console draws the same thing ---

  def test_the_console_draws_each_instance_facing_its_own_way
    prog = pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
      guards.spawn x: 20, y: 20
      guards.spawn x: 60, y: 20
      b.game_loop do
        b.wait_vblank
        guards.each { |g| (g.x == 20).then { g.face :left }.else { g.face :right } }
      end
    end

    rom = ROM.assemble(GBA.new.lower(prog), title: "POOLFACE", code: "BPLF", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)
    assert v.pixel_is?(22, 22, :red), "got 0x#{format('%04X', v.pixel_gba(22, 22))}"
    assert v.pixel_is?(62, 22, :green), "got 0x#{format('%04X', v.pixel_gba(62, 22))}"
  end

  # --- friendly errors ---

  def test_two_sources_of_pictures_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      pool_program(image: :left1, facing: { left: :left1 }) { |b, _| b.game_loop { b.wait_vblank } }
    end
    assert_match(/:guard/, error.message)
    assert_match(/image:/, error.message)
    assert_match(/facing:/, error.message)
  end

  def test_facing_a_direction_the_pool_does_not_have_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
        b.game_loop { b.wait_vblank; guards.each { |g| g.face :up } }
      end
    end
    assert_match(/:guard/, error.message)
    assert_match(/:up/, error.message)
    assert_match(/left, right/, error.message, "it says which directions there are")
  end

  def test_facing_at_all_on_a_pool_with_no_pictures_is_a_friendly_error
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        sparks = pool :spark, x: 0, y: 0, capacity: 4
        game_loop { wait_vblank; sparks.each { |s| s.face :left } }
      end
    end
    assert_match(/:spark/, error.message)
    assert_match(/facing:/, error.message, "it says what would give it directions")
  end

  def test_an_animation_with_no_rate_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      pool_program(frames: %i[left1 left2]) { |b, _| b.game_loop { b.wait_vblank } }
    end
    assert_match(/pool :guard/, error.message, "it says pool, not sprite")
    assert_match(/rate:/, error.message)
  end
end
