# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The shared per-scene screen-mode analysis. A game can run some scenes in
# direct color and others tear-free, and *which* scene draws in *which* mode is a
# property of the program, not of any target machine. This one analysis answers
# that so the backend, the palette, and the cost model all agree instead of each
# working it out. These tests build tiny programs straight from the IR (the
# analysis is what's under test, not the DSL) and assert the resolution.
class TestIRModes < Minitest::Test
  include RubyGBA::IR::Build

  Modes = RubyGBA::IR::Modes

  # A scene func: its screen declares +mode+ (:direct/:buffered), or nil to
  # inherit the mode it's reached in.
  def scene(name, mode, *draws)
    body = []
    body << screen(:bitmap, buffered: mode == :buffered) unless mode.nil?
    func(name, *body.concat(draws))
  end

  # A two-scene game: a title and a play scene, dispatched by :state, booting in
  # +boot+ mode.
  def game(title:, play:, boot: :direct)
    program(
      screen(:bitmap, buffered: boot == :buffered),
      set(:state, int(0)),
      scene(:_scene_title, title, clear_screen(:red)),
      scene(:_scene_play, play, clear_screen(:blue)),
      loop_(wait_vblank, case_(:state, [[0, :_scene_title], [1, :_scene_play]])),
    )
  end

  def test_default_mode_reads_the_top_level_screen
    assert_equal :direct, Modes.resolve(program(screen(:bitmap))).default_mode
    assert_equal :buffered, Modes.resolve(program(screen(:bitmap, buffered: true))).default_mode
  end

  # A scene that declares tear-free resolves buffered; a scene that declares
  # nothing inherits the boot mode.
  def test_a_declared_scene_resolves_its_own_mode
    m = Modes.resolve(game(title: nil, play: :buffered))
    assert_equal :direct, m.func_mode[:_scene_title] # inherits the direct boot
    assert_equal :buffered, m.func_mode[:_scene_play] # declares tear-free
  end

  # A helper a buffered scene calls draws on the buffered screen, so it inherits
  # that mode through the call graph.
  def test_a_helper_inherits_the_calling_scenes_mode
    prog = program(
      screen(:bitmap),
      set(:state, int(0)),
      func(:paint, clear_screen(:white)), # no screen of its own
      scene(:_scene_play, :buffered, call(:paint)),
      loop_(wait_vblank, case_(:state, [[0, :_scene_play]])),
    )
    assert_equal :buffered, Modes.resolve(prog).func_mode[:paint]
  end

  # One drawing routine reached from a direct scene and a buffered one can't draw
  # both ways — a friendly build error naming the routine, not a wrong screen.
  def test_a_helper_shared_across_modes_is_a_conflict
    prog = program(
      screen(:bitmap),
      set(:state, int(0)),
      func(:paint, clear_screen(:white)),
      scene(:_scene_a, nil, call(:paint)),          # direct (inherits boot)
      scene(:_scene_b, :buffered, call(:paint)),    # buffered
      loop_(wait_vblank, case_(:state, [[0, :_scene_a], [1, :_scene_b]])),
    )
    err = assert_raises(Modes::Conflict) { Modes.resolve(prog) }
    assert_match(/paint/, err.message)
    assert_match(/shared across screen modes/, err.message)
  end

  def test_mixed_when_scenes_use_different_modes
    assert Modes.resolve(game(title: :direct, play: :buffered)).mixed?
    refute Modes.resolve(game(title: :buffered, play: :buffered, boot: :buffered)).mixed?
    refute Modes.resolve(game(title: nil, play: nil)).mixed? # all inherit direct
  end

  def test_any_buffered
    assert Modes.resolve(game(title: :direct, play: :buffered)).any_buffered?
    refute Modes.resolve(game(title: nil, play: nil)).any_buffered?
  end

  # The palette only cares about the buffered scenes — those are the scopes it
  # walks for colors, so a direct scene's colors never count toward it.
  def test_buffered_scopes_are_the_buffered_funcs_only
    m = Modes.resolve(game(title: :direct, play: :buffered))
    names = m.buffered_scopes.map { |node| node[:name] }
    assert_includes names, :_scene_play
    refute_includes names, :_scene_title
  end

  # A program that boots buffered contributes its main body (top-level draws) as a
  # buffered scope too, not just its funcs.
  def test_buffered_boot_includes_the_main_body
    prog = program(screen(:bitmap, buffered: true), clear_screen(:blue), loop_(wait_vblank))
    scopes = Modes.resolve(prog).buffered_scopes
    assert(scopes.any? { |node| node.kind == :clear_screen || node.walk.any? { |n| n.kind == :clear_screen } })
  end

  def test_mode_of_an_unreached_func_is_the_boot_mode
    prog = program(screen(:bitmap, buffered: true), func(:never_called, clear_screen(:red)), loop_(wait_vblank))
    assert_equal :buffered, Modes.resolve(prog).mode_of(:never_called) # falls back to boot
  end

  def test_friendly_name_strips_the_scene_prefix
    assert_equal "play", Modes.friendly_name(:_scene_play)
    assert_equal "paint", Modes.friendly_name(:paint) # a plain func is unchanged
  end
end
