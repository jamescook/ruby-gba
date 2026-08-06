# frozen_string_literal: true

require "test_helper"

require "stringio"

# The effect registry: how a verb gets into the DSL from outside the framework.
#
# The thing worth asserting is that a registered verb is indistinguishable from a
# built-in one at the call site — a game writes it next to `fill_rect` and gets the
# same pixels — and that a pack's guardrails come and go with the pack. So these
# tests build real programs through the DSL and read the screen, rather than
# checking that a method got defined.
class TestEffectsRegistry < Minitest::Test
  Effects = RubyGBA::Effects
  Guardrails = RubyGBA::IR::Guardrails

  RED = RubyGBA::Color.resolve(:red)
  BLUE = RubyGBA::Color.resolve(:blue)

  # A pack: one verb written in plain DSL verbs, plus a private helper only its own
  # verb uses. Exactly the shape a third party would write.
  module Corners
    def paint_corner(color)
      fill_rect 0, 0, corner_size, corner_size, color
    end

    private

    def corner_size
      20
    end
  end

  # A second pack that wants the same verb name.
  module RivalCorners
    def paint_corner(_color)
      raise "never reached"
    end
  end

  # A pack that reaches for a name the framework already owns.
  module Impostor
    def clear_screen(_color)
      raise "never reached"
    end
  end

  # A pack that brings a guardrail with it: it errors on a program that sets :boom.
  module Watched
    def watched_verb
      set :boom, 1
    end

    def self.checks
      @checks ||= [BoomCheck.new]
    end

    class BoomCheck
      def detect(program)
        hit = program.each.find { |node| node.kind == :set && node[:var] == :boom }
        return [] unless hit

        [RubyGBA::IR::Guardrails::Finding.new(check: :boom, severity: :error,
                                              message: "boom found", node: hit)]
      end
    end
  end

  # Both registries are global. Snapshot the guardrail side and put it back, because
  # a loaded pack's checks live there too and clearing without restoring would switch
  # a shipped pack's guardrail off for every test that runs after this file.
  def setup
    @already_registered = Guardrails.registered_checks
  end

  def teardown
    Effects.clear_registered!
    Guardrails.clear_registered!
    @already_registered.each { |check| Guardrails.register(check) }
  end

  def program(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- what ships by default ---

  def test_the_shipped_packs_are_loaded_and_listable
    assert_includes Effects.packs, Effects::Packs::ScreenShake
    assert_equal Effects::Packs::ScreenShake, Effects.verbs[:shake_screen]
  end

  def test_a_shipped_pack_verb_is_an_ordinary_dsl_verb
    i = Reference.new.run(program do
      screen :bitmap
      clear_screen :blue
      frame = var :frame, 0
      game_loop do
        frame.add 1
        (frame == 1).then { shake_screen intensity: 4, frames: 4 }
        (frame >= 3).then { halt }
      end
    end)

    refute_equal 0, i.screen.camera_x, "the pack's verb did what a built-in verb would"
  end

  def test_verbs_hands_back_a_copy_callers_cannot_mutate
    Effects.verbs.clear

    refute_empty Effects.verbs, "the internal registry is untouched"
  end

  # --- registering a pack ---

  def test_a_packs_verb_draws_the_same_pixels_a_built_in_one_would
    RubyGBA.register_effects(Corners)
    i = Reference.new.run(program do
      screen :bitmap
      clear_screen :blue
      paint_corner :red
      halt
    end)

    assert_equal RED, i.screen.pixel(5, 5), "the registered verb drew"
    assert_equal BLUE, i.screen.pixel(30, 30), "and only where it was asked to"
  end

  def test_a_packs_private_helper_comes_along_but_stays_off_the_dsl
    RubyGBA.register_effects(Corners)

    assert RubyGBA::Builder.private_method_defined?(:corner_size),
           "the verb cannot work without the helper it calls"
    refute RubyGBA::Builder.public_method_defined?(:corner_size),
           "but a helper is not part of the DSL surface"
  end

  def test_registering_the_same_pack_twice_does_nothing_the_second_time
    RubyGBA.register_effects(Corners)
    RubyGBA.register_effects(Corners)

    assert_equal 1, Effects.packs.count(Corners)
  end

  def test_two_packs_cannot_take_one_verb_name
    RubyGBA.register_effects(Corners)

    err = assert_raises(Effects::DuplicateVerb) { RubyGBA.register_effects(RivalCorners) }
    assert_match(/paint_corner/, err.message)
    assert_match(/rename/, err.message, "it says what to do about it")
  end

  def test_a_pack_cannot_replace_a_framework_verb
    err = assert_raises(Effects::DuplicateVerb) { RubyGBA.register_effects(Impostor) }
    assert_match(/clear_screen/, err.message)

    i = Reference.new.run(program { screen :bitmap; clear_screen :blue; halt })
    assert_equal BLUE, i.screen.pixel(10, 10), "the real verb still means what it meant"
  end

  def test_a_pack_has_to_be_a_module
    err = assert_raises(ArgumentError) { RubyGBA.register_effects(3) }
    assert_match(/module/, err.message)
  end

  # --- registering a single verb from a block ---

  def test_an_inline_block_verb_runs_in_the_builder
    Effects.register(:paint_stripe) { |color| fill_rect 0, 40, 240, 10, color }
    i = Reference.new.run(program do
      screen :bitmap
      clear_screen :blue
      paint_stripe :red
      halt
    end)

    assert_equal RED, i.screen.pixel(120, 45), "the block ran with the builder as self"
    assert_equal BLUE, i.screen.pixel(120, 100)
  end

  def test_an_inline_verb_needs_a_block
    err = assert_raises(ArgumentError) { Effects.register(:no_body) }
    assert_match(/block/, err.message)
  end

  def test_an_inline_verb_cannot_take_a_name_that_is_taken
    assert_raises(Effects::DuplicateVerb) { Effects.register(:fill_rect) { nil } }
  end

  # --- unloading ---

  def test_clearing_takes_a_registered_pack_off_the_dsl_and_leaves_the_shipped_ones
    RubyGBA.register_effects(Corners)
    Effects.clear_registered!

    refute RubyGBA::Builder.method_defined?(:paint_corner), "the verb is gone"
    refute RubyGBA::Builder.private_method_defined?(:corner_size), "and so is its helper"
    assert RubyGBA::Builder.method_defined?(:shake_screen), "a shipped pack stays loaded"
  end

  def test_unregister_takes_one_verb_back_off
    Effects.register(:paint_stripe) { |_c| nil }

    assert Effects.unregister(:paint_stripe)
    refute Effects.unregister(:paint_stripe), "it was already gone"
    refute RubyGBA::Builder.method_defined?(:paint_stripe)
  end

  # --- a pack brings its own guardrails ---

  def test_a_packs_check_reports_on_a_real_build
    RubyGBA.register_effects(Watched)
    err = StringIO.new

    ex = assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("WATCH", code: "BWCH", maker: "01", err: err) do
        screen :bitmap
        watched_verb
        halt
      end
    end

    assert_match(/stopped/, ex.message)
    assert_match(/boom found/, err.string, "the pack's own explanation reached the person")
  end

  def test_a_packs_checks_go_away_with_the_pack
    RubyGBA.register_effects(Watched)
    Effects.clear_registered!

    refute_includes Guardrails.registered_checks, Watched.checks.first,
                    "an unloaded pack's guardrail must not report on other games"
  end

  # The shipped pack's own guardrail, reached the way a build reaches it — through
  # the registry, not by naming the check class.
  def test_the_shake_pack_brings_its_guardrail_with_it
    findings = Guardrails::Validator.new.run(program do
      screen :bitmap
      clear_screen :blue
      shake_screen intensity: 4, frames: 8
      halt
    end, autofix: false).findings

    assert_includes findings.map(&:check), :shake_needs_game_loop
  end

  # --- the boundary the registry documents ---

  # The rule at the seam: a pack composes PUBLIC DSL verbs. It does not build IR
  # nodes or touch hardware — that is kernel work, and a "pack" that did it would
  # need lowering in every backend. Read the pack sources for the machinery rather
  # than trying to catch it at run time.
  #
  # Reading the IR is fine and is not scanned for: a pack's guardrail check is handed
  # the finished program and walks it, which is what every check does. Building IR is
  # the line.
  def test_a_pack_builds_its_verbs_out_of_public_verbs
    packs = Dir[File.expand_path("../lib/ruby_gba/effects/packs/*.rb", __dir__)]
    refute_empty packs, "the packs should be where this test looks for them"

    machinery = { "Build." => "builds IR nodes", "record(" => "records IR directly",
                  "REG_" => "names a hardware register", "ASM." => "emits instructions" }
    offenders = packs.flat_map do |path|
      source = File.read(path)
      machinery.filter_map { |token, what| "#{File.basename(path)} #{what}" if source.include?(token) }
    end

    assert_empty offenders,
                 "a pack composes public DSL verbs; anything lower belongs in the kernel"
  end

  # --- each_frame: the seam a pack composes on ---

  def test_an_each_frame_body_runs_once_on_every_frame
    i = Reference.new.run(program do
      screen :bitmap
      ticks = var :ticks, 0
      frame = var :frame, 0
      each_frame { ticks.add 1 }
      game_loop do
        frame.add 1
        (frame >= 5).then { halt }
      end
    end)

    assert_equal 5, i[:ticks]
  end

  # The whole point of the verb: the game's own code took a different path this
  # frame — a different scene entirely — and the body still ran.
  def test_it_runs_on_frames_the_games_own_code_does_not
    i = Reference.new.run(program do
      screen :bitmap
      var :state, 0
      ticks = var :ticks, 0
      title_ran = var :title_ran, 0
      play_ran = var :play_ran, 0
      frame = var :frame, 0

      each_frame { ticks.add 1 }

      scene(:title) do
        title_ran.add 1
        (frame >= 2).then { set :state, 1 }
      end
      scene(:playing) { play_ran.add 1 }

      game_loop do
        frame.add 1
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
        (frame >= 4).then { halt }
      end
    end)

    assert_equal 2, i[:title_ran], "each scene ran only while it was the active one"
    assert_equal 2, i[:play_ran]
    assert_equal 4, i[:ticks], "the each_frame body ran on all four frames"
  end

  def test_a_program_with_no_game_loop_never_runs_it
    i = Reference.new.run(program do
      screen :bitmap
      ticks = var :ticks, 0
      each_frame { ticks.add 1 }
      halt
    end)

    assert_equal 0, i[:ticks], "no frames, so nothing to run on"
  end

  def test_each_frame_needs_a_block
    err = assert_raises(ArgumentError) { program { screen :bitmap; each_frame } }
    assert_match(/block/, err.message)
  end
end
