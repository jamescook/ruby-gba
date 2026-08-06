# frozen_string_literal: true

require "test_helper"

# A spriteful pool: give a pool an image: and each live instance draws itself as a
# hardware sprite at its x/y (spawn shows one, remove hides it), and gains a collision
# box — overlaps? / the screen-edge tests / clamp_to_screen work per instance. Behind
# the scenes it's one hardware-sprite object per slot, bound to the field lists, drawn by
# the console's sprite hardware. Pinned on the interpreter and on gemba.
class TestPoolSprites < Minitest::Test

  GREEN = Color.resolve(:green)
  BLACK = 0

  # A tiled program with an :ufo image (8x8 green) and an enemy pool; the block spawns
  # instances and adds per-frame behavior via the pool handle.
  def enemy_program
    b = Builder.new
    handle = nil
    b.instance_eval do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      handle = pool :enemy, x: 0, y: 0, capacity: 8, image: :ufo
      yield(self, handle)
    end
    b.emit_pending_functions
    b.program
  end

  def test_spawn_shows_a_sprite_per_live_instance
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 20, y: 20
      enemies.spawn x: 60, y: 40
      b.game_loop { b.wait_vblank }
    end
    i = Reference.new.run(prog)
    assert_equal GREEN, i.screen.pixel(22, 22), "first instance's sprite drew at its x/y"
    assert_equal GREEN, i.screen.pixel(62, 42), "second instance's sprite drew at its x/y"
    assert_equal BLACK, i.screen.pixel(150, 100), "nowhere an instance isn't"
  end

  def test_remove_hides_an_instances_sprite
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 20, y: 20
      enemies.spawn x: 60, y: 40
      b.game_loop do
        b.wait_vblank
        enemies.each { |e| (e.x == 60).then { e.remove } }
      end
    end
    i = Reference.new.run(prog)
    assert_equal GREEN, i.screen.pixel(22, 22), "the kept instance still draws"
    assert_equal BLACK, i.screen.pixel(62, 42), "the removed instance's sprite is gone"
  end

  # overlaps? works on an instance (its box is its x/y plus the image's size): an
  # overlapping box registers a hit, a far one does not.
  def test_an_instance_collides_via_its_sprite_box
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      var :near_hit, 0
      var :far_hit, 0
      enemies = pool :enemy, x: 0, y: 0, capacity: 8, image: :ufo
      near = box(50, 50, 8, 8)
      far = box(150, 100, 8, 8)
      enemies.spawn x: 52, y: 52 # overlaps `near`, not `far`
      game_loop do
        wait_vblank
        enemies.each do |e|
          e.overlaps?(near).then { set :near_hit, 1 }
          e.overlaps?(far).then { set :far_hit, 1 }
        end
      end
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    assert_equal 1, i[:near_hit], "the instance overlapping the box registers a hit"
    assert_equal 0, i[:far_hit], "and doesn't false-positive on a far box"
  end

  # off_screen? works on an instance: one spawned past the edge removes itself, an
  # on-screen one stays.
  def test_off_screen_test_works_on_an_instance
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 300, y: 60 # off the right edge
      enemies.spawn x: 40, y: 60  # on screen
      b.game_loop do
        b.wait_vblank
        enemies.each { |e| e.off_screen?.then { e.remove } }
      end
    end
    i = Reference.new.run(prog)
    assert_equal 1, i[:__pool_enemy_count], "the off-screen instance was removed, the on-screen one kept"
  end

  # clamp_to_screen pins an instance on screen using its sprite size — one spawned off
  # the bottom-right corner is pulled back and drawn at the edge.
  def test_clamp_to_screen_works_on_an_instance
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 300, y: 300 # off the bottom-right
      b.game_loop do
        b.wait_vblank
        enemies.each(&:clamp_to_screen)
      end
    end
    i = Reference.new.run(prog)
    # 8x8 sprite clamps its top-left to (240-8, 160-8) = (232, 152)
    assert_equal GREEN, i.screen.pixel(234, 154), "the instance was pinned to the bottom-right edge"
  end

  # A pool declared inside a scene is scene-owned: its sprites show only while that scene
  # is the active state (the same gating scene-owned hardware sprites use).
  def test_a_scene_owned_pool_shows_only_while_its_scene_is_active
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      var :state, 0
      scene :menu do
        # nothing drawn here
      end
      scene :play do
        wave = pool :enemy, x: 0, y: 0, capacity: 4, image: :ufo
        (wave.count == 0).then { wave.spawn x: 50, y: 50 } # spawn once, when empty
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :menu
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions
    prog = b.program

    on_menu = Reference.new.run(prog) # state 0: the play pool is hidden
    assert_equal BLACK, on_menu.screen.pixel(52, 52), "the pool's sprites are hidden on the menu scene"

    # start on :play (state 1): the pool's sprite shows
    b2 = Builder.new
    b2.instance_eval do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      var :state, 1
      scene(:menu) {}
      scene :play do
        wave = pool :enemy, x: 0, y: 0, capacity: 4, image: :ufo
        (wave.count == 0).then { wave.spawn x: 50, y: 50 }
      end
      game_loop { wait_vblank; case_var(:state) { when_val 0, :menu; when_val 1, :play } }
    end
    b2.emit_pending_functions
    on_play = Reference.new.run(b2.program)
    assert_equal GREEN, on_play.screen.pixel(52, 52), "the pool's sprite shows while its scene is active"
  end

  # --- guardrails ---

  def test_a_spriteful_pool_needs_a_tiled_screen
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        image(:ufo, "#" => :green) { "########\n" * 8 }
        pool :enemy, x: 0, y: 0, capacity: 8, image: :ufo
      end
    end
    assert_match(/tiled/i, err.message)
  end

  def test_a_spriteful_pool_needs_x_and_y_fields
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image(:ufo, "#" => :green) { "########\n" * 8 }
        pool :enemy, hp: 3, capacity: 8, image: :ufo
      end
    end
    assert_match(/x:/, err.message)
  end

  def test_a_spriteful_pool_needs_a_defined_image
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        pool :enemy, x: 0, y: 0, capacity: 8, image: :missing
      end
    end
    assert_match(/image :missing/, err.message)
  end

  # --- hardware ---

  def test_a_spriteful_pool_draws_on_the_console
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 30, y: 30
      enemies.spawn x: 80, y: 80
      b.game_loop { b.wait_vblank }
    end
    rom = ROM.assemble(GBA.new.lower(prog), title: "PSPR", code: "BPSP", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.green?(33, 33), "a pooled sprite drew on the console, got 0x#{format('%04X', v.pixel_gba(33, 33))}"
    assert v.green?(83, 83), "and the second one too"
  end
end
