# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# The stand-in a test is handed on a native run in place of the interpreter (see
# Native::HeadlessRun): the game built with no window, driven and read back through the same
# calls a test already makes on Backends::Reference.
class TestNativeHeadlessRun < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun

  def test_a_variable_reads_back_after_the_run
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_equal 6, HeadlessRun.new.run(program, frames: 6)[:ticks]
  end

  # The program prints its own lines beside the game's variables ("frame 3", "picture …"), and a
  # game may call a variable by either word.
  def test_a_variable_may_share_a_name_with_the_lines_around_it
    program = program_of do
      frame = var :frame, 0
      picture = var :picture, 7
      game_loop do
        frame.add! 1
        picture.add! 2
      end
    end
    run = HeadlessRun.new.run(program, frames: 5)

    assert_equal [5, 17], [run[:frame], run[:picture]]
    assert_equal [1, 2, 3, 4, 5, :end], run.moments.map(&:frame)
  end

  # The block is asked for each frame's buttons while the game runs, and can look at the game
  # to decide: here it holds RIGHT only until x has reached 3, so x stops there. A block that
  # saw the game a frame late, or not at all, would hold RIGHT once too often.
  def test_buttons_for_each_frame_can_depend_on_the_game_so_far
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    run = HeadlessRun.new
    run.input_each_frame { |_frame| run[:x] < 3 ? [:right] : [] }

    assert_equal 3, run.run(program, frames: 8)[:x]
  end

  def test_buttons_held_for_the_whole_run
    program = program_of do
      x = var :x, 0
      game_loop { held(:left).then { x.add! 1 } }
    end

    assert_equal 4, HeadlessRun.new.hold(:left).run(program, frames: 4)[:x]
  end

  # A RUN THAT IS SLOW IS NOT A RUN THAT IS STUCK. The game is talked to a frame at a time, and
  # each answer waits its turn among Ruby's threads, so beside busy ones a run of many frames
  # takes far longer than the game does. What is timed is how long the program takes to reach
  # its next frame once it has that frame's buttons. Here the buttons are slow to come, as they
  # are when this thread is waiting its turn: the whole run takes longer than the limit, and no
  # one frame comes near it. (The limit is seconds and not a fraction of one because a busy
  # machine can keep a program from starting for that long.)
  def test_a_run_slower_than_the_limit_is_not_taken_to_be_stuck
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end
    run = HeadlessRun.new.allowing_each_frame(3)
    run.input_each_frame do |_frame|
      sleep 0.4
      []
    end

    assert_equal 10, run.run(program, frames: 10)[:ticks]
  end

  # A game that never waits for the screen, so it never ends a frame, built from what +game+
  # says. Such a game never ends on its own.
  def game_with_no_frames(&game)
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(frame_sync: :manual))
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  def assert_stopped_before_its_first_frame(program)
    error = assert_raises(RubyGBA::IR::Backends::Native::Zig::Error) do
      HeadlessRun.new.allowing_each_frame(1).run(program, frames: 3)
    end

    assert_match(/had not reached the frame after frame 0/, error.message)
    assert_match(/was stopped/, error.message)
  end

  # And one that is stuck is stopped, saying how far it got: here one that prints nothing.
  def test_a_game_that_never_reaches_a_frame_is_stopped
    assert_stopped_before_its_first_frame(game_with_no_frames do
      x = var :x, 0
      game_loop { x.add! 1 }
    end)
  end

  # One that is stuck can go on printing: this one beeps every time round, and each beep is a
  # line. It is no nearer a frame for that, and is stopped all the same.
  def test_a_game_that_prints_without_reaching_a_frame_is_stopped
    assert_stopped_before_its_first_frame(game_with_no_frames do
      enable_sound
      define_sound :blip, frequency: 880, duty: :half, decay: :fast, volume: 12
      game_loop { beep :blip }
    end)
  end

  # A dot that moves three across every pass, on a screen cleared first: where the dot is says
  # which pass the picture is of.
  def moving_dot
    program_of do
      screen :bitmap
      x = var :x, 0
      game_loop do
        clear_screen :black
        draw_rect_at x, 20, 1, 1, :green
        x.add! 3
      end
    end
  end

  def dot_column(screen) = (0...40).find { |x| screen.pixel(x, 20) == Color.resolve(:green) }

  # WATCHING A RUN FRAME BY FRAME, the way a test watches the interpreter: the block is run at
  # every frame boundary with the frame's number, and the game reads then as it stood at that
  # boundary. The interpreter's own watch of the same game is the answer.
  def test_a_watched_run_reads_each_frame_as_it_stood
    interpreter = Reference.new
    expected = []
    interpreter.each_vblank { |frame| expected << [frame, interpreter[:x], dot_column(interpreter.screen)] }
    interpreter.run(moving_dot, frames: 5)

    seen = []
    run = HeadlessRun.new
    run.each_vblank { |frame| seen << [frame, run[:x], dot_column(run.screen)] }
    run.run(moving_dot, frames: 5)

    assert_equal expected, seen
    assert_equal [5, 12, 9], seen.last, "the dot should have moved, and the picture be a pass behind the count"
  end

  # The picture a watched frame reads is whole: as it is shown, and as it is stored.
  def test_a_watched_frame_reads_the_stored_picture_too
    program = program_of do
      screen :bitmap, tear_free: true
      level = var :level, 0
      game_loop do
        clear_screen :blue
        draw_rect_at 100, 60, 40, 40, :yellow
        camera 30, 10
        fade :black, level
        level.add! 10
      end
    end
    interpreter = Reference.new
    expected = []
    interpreter.each_vblank { expected << [interpreter.screen.shown.dup, interpreter.screen.to_a] }
    interpreter.run(program, frames: 4)

    seen = []
    run = HeadlessRun.new
    run.each_vblank { seen << [run.screen.shown, run.screen.to_a] }
    run.run(program, frames: 4)

    assert_equal expected, seen
    refute_equal seen.last.first, seen.last.last, "the faded picture is not the stored one"
    refute_equal seen[1].first, seen.last.first, "the fade should have moved between frames"
  end

  # An input script can look at the picture before it decides, as it can at a variable: RIGHT is
  # held until the dot is seen at column 6, and the picture is a pass behind the count, so by
  # then the count has gone one step further.
  def test_an_input_script_can_read_the_picture_so_far
    program = program_of do
      screen :bitmap
      x = var :x, 0
      game_loop do
        clear_screen :black
        draw_rect_at x, 20, 1, 1, :green
        held(:right).then { x.add! 3 }
      end
    end
    run = HeadlessRun.new
    run.input_each_frame { |_frame| (dot_column(run.screen) || 0) < 6 ? [:right] : [] }

    assert_equal 9, run.run(program, frames: 10)[:x]
  end

  # A small cast: a hero walking right and drawn in other colors, a coin the game has switched
  # off, a walker stepping between two pictures, shots from a pool as A is pressed, and a word.
  def cast
    program_of do
      screen :tiled
      image(:hero, colors: %i[transparent red], "#" => :red) { SOLID_TILE }
      image(:coin, "#" => :yellow) { SOLID_TILE }
      image(:step_a, "#" => :green) { SOLID_TILE }
      image(:step_b, "#" => :blue) { SOLID_TILE }
      image(:bullet, "#" => :white) { SOLID_TILE }
      colors :hurt, %i[transparent white]
      hero = sprite :hero, at: [40, 40]
      sprite :coin, at: [100, 80], shown: false
      sprite :walker, at: [8, 100], frames: %i[step_a step_b], rate: 2
      shots = pool :shot, x: 0, y: 0, capacity: 4, image: :bullet
      draw_text "HI", 8, 8, :white
      game_loop do
        hero.move :right, by: 2
        hero.draw_with :hurt
        pressed(:a).then { shots.spawn(x: hero.x, y: 60) }
      end
    end
  end

  # A press of A on frames 2 and 5, so two shots are spawned where the hero then stood.
  def pressing_a(player) = player.input_each_frame { |frame| [2, 5].include?(frame) ? [:a] : [] }

  def drawn(name, x, y, picture) = RubyGBA::Diagnostics::DrawnSprite.new(name: name, x: x, y: y, picture: picture)

  # WHICH SPRITE IS WHICH, asked the way a test asks the interpreter: every row the game drew,
  # each saying whose it is, where it is, and which of its pictures it shows by the name the
  # author gave that picture, whatever colors it is drawn in.
  def test_the_sprites_drawn_read_back_as_the_interpreters_do
    interpreter = pressing_a(Reference.new).run(cast, frames: 8)

    run = pressing_a(HeadlessRun.new).run(cast, frames: 8)

    assert_equal interpreter.sprites, run.sprites
    assert_equal [drawn(:hero, 54, 40, :hero)], run.sprites(:hero)
    assert_empty run.sprites(:coin), "the coin is switched off"
    assert_equal [drawn(:shot, 50, 60, :bullet), drawn(:shot, 44, 60, :bullet)], run.sprites(:shot),
                 "back to front: a pool's older thing is in front, so the newer shot comes first"
    assert_equal [nil, nil], run.sprites.map(&:name).last(2), "a letter of text is nobody's sprite"
  end

  def test_a_sprite_the_game_does_not_have_is_refused_as_the_interpreter_refuses_it
    interpreter = Reference.new.run(cast, frames: 2)
    expected = assert_raises(ArgumentError) { interpreter.sprites(:dragon) }

    error = assert_raises(ArgumentError) { HeadlessRun.new.run(cast, frames: 2).sprites(:dragon) }

    assert_equal expected.message, error.message
    assert_match(/Its sprites are: :hero, :coin, :walker, :shot\./, error.message)
  end

  # A watching block is told the sprites of the frame it is on.
  def test_a_watched_frame_reads_the_sprites_drawn_then
    interpreter = pressing_a(Reference.new)
    expected = []
    interpreter.each_vblank { expected << interpreter.sprites }
    interpreter.run(cast, frames: 8)

    seen = []
    run = pressing_a(HeadlessRun.new)
    run.each_vblank { seen << run.sprites }
    run.run(cast, frames: 8)

    assert_equal expected, seen
    assert_equal %i[step_a step_b], seen.map { |rows| rows.find { |row| row.name == :walker }&.picture }.compact.uniq.sort
    assert_operator seen.map { |rows| rows.count { |row| row.name == :shot } }.uniq.length, :>, 1, "shots arrive as the run goes"
  end

  # Every variable at once, the way the interpreter's `vars` gives them.
  def test_every_variable_reads_back_together
    program = program_of do
      a = var :a, 2
      b = var :b, 0
      game_loop { b.add! a }
    end

    assert_equal({ a: 2, b: 6 }, HeadlessRun.new.run(program, frames: 3).vars.slice(:a, :b))
  end

  # Told no number of frames, it plays as many as the interpreter does when it is not told.
  def test_a_run_given_no_frame_count_plays_the_interpreters_default
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_equal Reference::DEFAULT_FRAMES, HeadlessRun.new.run(program)[:ticks]
  end

  # A step budget is something only the interpreter keeps: the C runs as fast as it runs.
  def test_a_step_budget_is_refused_by_name
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new.run(program_of { halt }, max_steps: 100) }

    assert_match(/max_steps/, error.message)
  end

  def test_starting_from_save_memory_is_refused_until_the_native_lowering_can_hold_one
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new(save: SaveImage.new) }

    assert_match(/save memory/, error.message)
  end

  # A test asking something only the interpreter can answer so far is told so by name, rather
  # than meeting a NoMethodError that reads like a typo in the test.
  def test_a_question_only_the_interpreter_can_answer_yet_says_so
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new.game_state }

    assert_match(/game_state/, error.message)
  end

  # The sound comes as so many numbers a second, and the C and the Ruby each say how many.
  def test_the_sound_rate_is_the_one_the_runtime_makes_it_at
    header = File.read(File.join(RubyGBA::IR::Backends::Native::Zig::RUNTIME_DIR, "rg_sound.h"))

    assert_match(/^#define RG_SOUND_RATE #{HeadlessRun::SOUND_RATE}$/, header)
  end

  def test_the_picture_reads_back_a_pixel_at_a_time
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        pixel 10, 20, :green
      end
    end
    run = HeadlessRun.new.run(program, frames: 2)

    assert_equal Color.resolve(:green), run.screen.pixel(10, 20)
    assert_equal Color.resolve(:black), run.screen.pixel(11, 20)
  end

  # The picture as it is STORED is not the one shown once the window has moved or a fade is on:
  # to_a gives the stored one, as the interpreter's does, and whether the screen is tear-free
  # reads back too.
  def test_the_stored_picture_and_the_kind_of_screen_read_back_as_the_interpreters_do
    program = program_of do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :blue
        draw_rect_at 100, 60, 40, 40, :yellow
        camera 30, 10
        fade :black, 50
      end
    end
    interpreter = Reference.new.run(program, frames: 3)

    run = HeadlessRun.new.run(program, frames: 3)

    assert_equal interpreter.screen.to_a, run.screen.to_a
    assert_equal interpreter.screen.shown, run.screen.shown
    refute_equal run.screen.shown.first(40), run.screen.to_a.first(40), "the faded picture is not the stored one"
    assert_equal interpreter.buffered, run.buffered
    assert run.buffered, "this screen is tear-free"
  end
end
