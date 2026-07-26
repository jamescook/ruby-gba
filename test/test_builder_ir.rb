# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The DSL builds an IR tree, which RubyGBA.build lowers to a ROM. These tests
# assert the DSL constructs the RIGHT tree — without lowering anything — so a
# mistake in how a DSL method shapes the tree is caught here directly. (The
# lowered output is exercised by the behavioral backend tests.)
class TestBuilderIR < Minitest::Test
  include RubyGBA::IR::Build # the expected-tree constructors

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby

  # Build through the DSL and hand back the IR tree it constructed. Functions are
  # deferred in the DSL (so call/func order is free), so their bodies are only
  # evaluated — and recorded — when emit_pending_functions runs, just like a real
  # build does.
  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def test_variable_ops_build_a_matching_ir_tree
    got = tree do
      var :x, 5        # var is an alias for set
      set :y, 10
      add :x, 3        # immediate operand
      sub :x, :y       # variable operand
      copy :z, :x
      flip :z          # flip is an alias for negate
      abs :z
      negate_abs :z
      clamp :x, 0, 100
    end

    assert_equal program(
      set(:x, 5),
      set(:y, 10),
      add(:x, 3),
      sub(:x, :y),
      copy(:z, :x),
      negate(:z),
      abs(:z),
      negate_abs(:z),
      clamp(:x, 0, 100),
    ), got
  end

  def test_clamp_records_one_node_not_its_byte_expansion
    # The legacy clamp expands to a pair of compares in bytes, but in the IR it
    # is a single clamp node — the inner set/if calls must not leak in.
    got = tree { clamp :hp, 0, 100 }
    assert_equal 1, got.children.size
    assert_equal :clamp, got.children.first.kind
  end

  def test_the_built_tree_runs_in_the_interpreter
    # Structural equality proves the shape; running it proves the meaning. The
    # same tree the DSL built executes on the Ruby backend and clamps as intended.
    got = tree do
      var :x, 10
      add :x, 100     # 110
      clamp :x, 0, 20 # -> 20
    end
    assert_equal 20, Ruby.new.run(got)[:x]
  end

  def test_draw_ops_build_a_matching_ir_tree
    got = tree do
      screen :bitmap
      clear_screen :black
      pixel 10, 20, :red
      fill_rect 5, 5, 4, 3, :green
      dma_fill_rect 100, 50, 2, 12, :gray
      draw_rect_at :ball_x, 40, 4, 4, :white # variable x position
      draw_text "HI", 40, 30, :white
    end

    assert_equal program(
      screen(:bitmap),
      clear_screen(:black),
      pixel(10, 20, :red),
      fill_rect(5, 5, 4, 3, :green),
      dma_fill_rect(100, 50, 2, 12, :gray),
      draw_rect_at(:ball_x, 40, 4, 4, :white),
      draw_text("HI", 40, 30, :white),
    ), got
  end

  def test_the_built_draw_tree_renders_in_the_interpreter
    got = tree do
      screen :bitmap
      clear_screen :black
      pixel 10, 20, :red
      fill_rect 5, 5, 4, 3, :green
    end
    screen = Ruby.new.run(got).screen
    assert_equal RubyGBA::Color.resolve(:red), screen.pixel(10, 20)
    assert_equal RubyGBA::Color.resolve(:green), screen.pixel(5, 5)
    assert_equal RubyGBA::Color.resolve(:black), screen.pixel(0, 0)
  end

  # ---- control flow: nesting, conditions, funcs, dispatch ----

  def test_control_flow_builds_a_nested_ir_tree
    got = tree do
      set :x, 0
      func :bump do
        add :x, 1
      end
      game_loop do
        wait_vblank
        if_gt :x, 5 do        # condition becomes a binop over var + operand
          set :x, 0
        end
        call :bump
        if_held :up do        # condition becomes a held(:up) read
          add :x, 10
        end
      end
    end

    assert_equal program(
      set(:x, 0),
      loop_(
        wait_vblank,
        if_(binop(:>, var_ref(:x), int(5)), set(:x, 0)),
        call(:bump),
        if_(held(:up), add(:x, 10)),
      ),
      func(:bump, add(:x, 1)), # deferred funcs land after the main flow
    ), got
  end

  def test_scene_and_case_var_build_func_and_case_nodes
    got = tree do
      var :state, 0
      scene :title do
        clear_screen :black
      end
      scene :playing do
        clear_screen :white
      end
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end

    # A scene is a func named _scene_<name>; case_var is one case node whose
    # clauses point at those scene funcs.
    assert_equal program(
      set(:state, 0),
      loop_(
        case_(:state, 0 => :_scene_title, 1 => :_scene_playing),
      ),
      func(:_scene_title, clear_screen(:black)),
      func(:_scene_playing, clear_screen(:white)),
    ), got
  end

  def test_if_pressed_builds_a_pressed_condition
    got = tree { if_pressed(:start) { set :go, 1 } }
    assert_equal program(if_(pressed(:start), set(:go, 1))), got
  end

  def test_the_built_control_flow_tree_runs_in_the_interpreter
    # Build a loop that calls a func until a counter reaches the limit, then run
    # the exact tree the DSL built and check the counter.
    got = tree do
      set :x, 0
      func :bump do
        add :x, 1
      end
      game_loop do
        call :bump
        if_ge :x, 3 do
          halt
        end
      end
    end
    assert_equal 3, Ruby.new.run(got)[:x]
  end

  # ---- sound ----

  def test_sound_ops_build_a_matching_ir_tree
    got = tree do
      enable_sound
      define_sound :hit, frequency: 880, duty: :quarter, decay: :fast, volume: 12
      song :tune do
        tempo 120        # 30 frames per quarter note
        note :C4, :quarter # C4 = 262 Hz, at frame 0
        rest :quarter      # rest at frame 30
      end
      beep :hit
      play_song :tune
      stop_music
    end

    assert_equal program(
      enable_sound,
      define_sound(:hit, frequency: 880, duty: :quarter, decay: :fast, volume: 12),
      song(:tune, events: [[0, 262], [30, 0]], total_frames: 60, duty: :half, volume: 12),
      beep(:hit),
      play_song(:tune),
      stop_music,
    ), got
  end

  def test_the_built_sound_tree_runs_in_the_interpreter
    got = tree do
      enable_sound
      beep :high
      stop_music
    end
    audio = Ruby.new.run(got).audio
    assert_equal [:enabled], audio[0]
    assert_equal 880, audio[1][1][:frequency] # :high resolves to 880 Hz
    assert_equal [:stop_music], audio.last
  end

  # ---- everything together: draws + sound + control + funcs in one tree ----

  def test_a_full_mini_program_builds_and_runs
    got = tree do
      screen :bitmap
      enable_sound
      var :score, 0
      func :award do
        add :score, 1
        beep :high
      end
      game_loop do
        wait_vblank
        call :award
        if_ge :score, 2 do
          stop_music
          halt
        end
      end
    end

    i = Ruby.new.run(got)
    assert_equal 2, i[:score]
    assert_equal 2, i.audio.count { |e| e[0] == :beep } # awarded twice
  end
end
