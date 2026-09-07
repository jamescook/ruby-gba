# frozen_string_literal: true

require "test_helper"

require "stringio"

# The two ways a game's block becomes a program — on the way to a cartridge, and when
# something asks a Game what it is — held against each other. They were written out twice
# and drifted, so what these tests pin is that there is one answer and not two.
class TestEvaluatedGame < Minitest::Test
  Progress = RubyGBA::Progress

  # A game that stops half way through itself. The blue clear is in the program; the red
  # one is written after the `debug_halt` and never happened.
  def truncated_game
    RubyGBA.game("DBGHLT", code: "ZDBG", maker: "01") do
      screen :bitmap
      clear_screen :blue
      debug_halt
      clear_screen :red # never recorded
    end
  end

  # `debug_halt` throws to stop the block where it stands. #build_rom caught it and
  # answered a truncated ROM; asking the same game for its program raised instead, so a
  # game anyone was bisecting could not be run in a test, profiled, or explained.
  def test_a_game_that_stops_early_answers_its_program_the_way_it_answers_its_rom
    program = nil
    capture_io { program = truncated_game.program } # swallow the debug_halt reminder

    screen = Reference.new.run(program).screen
    assert_equal Color.resolve(:blue), screen.pixel(120, 80), "the draw before debug_halt ran"
    refute_equal Color.resolve(:red), screen.pixel(120, 80), "the draw after it never happened"
  end

  # ...and the two answers describe the same short program, which is the thing that drifted.
  def test_the_two_paths_truncate_a_game_at_the_same_point
    rom = nil
    program = nil
    capture_io do
      game = truncated_game
      program = game.program
      rom = game.build_rom(out: StringIO.new, err: StringIO.new, validate: false)
    end

    same = RubyGBA::ROM.assemble(GBA.new.lower(program), title: "DBGHLT", code: "ZDBG",
                                                         maker: "01", validate: false)
    assert_equal same.buffer, rom.buffer, "the tree a test runs is the tree that ships"
  end

  # A game's block is the slowest thing in a build — it is where the art and the levels are
  # read off disk — and the profiler asks for a program once per scene plus once more. Every
  # one of those used to be another run of somebody else's code.
  def test_asking_a_game_for_its_program_runs_its_block_once_however_often_you_ask
    runs = 0
    game = RubyGBA.game("ONCE", code: "ZONC", maker: "01") do
      runs += 1
      screen :bitmap
      clear_screen :black
      halt
    end

    3.times { game.program }

    assert_equal 1, runs
  end

  # ...and it is the same tree each time, which is what lets the profiler and a cost report
  # share one without either paying for it twice.
  def test_the_program_a_game_answers_is_the_same_tree_every_time
    game = RubyGBA.game("SAME", code: "ZSAM", maker: "01") do
      screen :bitmap
      clear_screen :black
      halt
    end

    assert_same game.program, game.program
  end

  # Sharing one tree is only safe while nothing rewrites what it is handed. A cartridge
  # built after the tree has been round the interpreter and the cost report must be the
  # cartridge built from a tree nobody touched.
  def test_a_game_builds_the_same_cartridge_after_something_has_read_its_program
    fresh = a_small_game.build_rom(out: StringIO.new, err: StringIO.new)

    read = a_small_game
    Reference.new.run(read.program, frames: 4)
    RubyGBA::IR::CostModel.new.render(read.program, out: StringIO.new, color: :never)

    assert_equal fresh.buffer, read.build_rom(out: StringIO.new, err: StringIO.new).buffer
  end

  def a_small_game
    RubyGBA.game("SMALL", code: "ZSML", maker: "01") do
      screen :bitmap
      x = var :x, 10
      game_loop do
        clear_screen :black
        draw_rect_at x, 40, 20, 20, :green
        x.add 1
      end
    end
  end

  # A game declares its own frame timing, and the tree a test runs has to be paced the way
  # the cartridge is or a test measures a game nobody ships. Counted the way frame timing is
  # always counted here: how many passes the loop makes over five frames.
  def test_a_game_keeps_its_own_frame_timing_when_something_asks_what_it_is
    unpaced = RubyGBA.game("MANUAL", code: "ZMAN", maker: "01", frame_sync: :manual) do
      screen :bitmap
      n = var :n, 0
      game_loop { n.add 1 }
    end

    ran = Reference.new.run(unpaced.program, frames: 5)

    assert_predicate ran, :stopped_at_budget?, "nothing paces a manual loop with no sync in it"
    assert_operator ran[:n], :>, 5, "so it runs its body far more than once per frame"
  end

  # A game may say what it is doing while its block runs (reading sixty floors of a map,
  # chewing through a sprite sheet). Whether anyone is listening is decided by the caller,
  # and these two callers decide differently on purpose: a person waiting on a build hears
  # it, and a test asking what a game IS does not.
  def test_a_game_says_what_it_is_doing_while_a_person_waits_on_a_build
    out = StringIO.new
    talkative_game.build_rom(out: StringIO.new, err: StringIO.new, progress: Progress.to(out))

    assert_includes out.string, "reading the floors"
  end

  # Asked of the block itself rather than of an output stream, because a stream cannot tell
  # the two apart: a phase that nobody ever closes writes nothing anywhere, so an empty
  # stream is equally what a listening build looks like half way through.
  def test_a_game_says_nothing_while_something_asks_what_it_is
    heard = nil
    game = RubyGBA.game("QUIET", code: "ZQUI", maker: "01") do
      heard = progress
      screen :bitmap
      clear_screen :black
      halt
    end

    game.program

    assert_same Progress.silent, heard
  end

  def talkative_game
    RubyGBA.game("TALKY", code: "ZTLK", maker: "01") do
      progress.step "reading the floors"
      screen :bitmap
      clear_screen :black
      halt
    end
  end

  # What the run learned that is not in the tree — the facts the guardrails report from.
  # They come off the evaluated game now rather than out of the Builder, so the class a
  # person learns the DSL from is not also the build pipeline's surface.
  def test_it_carries_what_the_run_learned_that_the_tree_cannot_hold
    evaluated = RubyGBA::EvaluatedGame.new(proc do
      screen :bitmap
      x = var :x, 0
      game_loop do
        wait_vblank # the loop already covers this one
        x > 3       # a Condition built and never branched on
      end
    end)

    assert_equal 1, evaluated.dropped_syncs
    assert_equal 1, evaluated.pending_conditions.length
    refute_predicate evaluated, :debug_halted?
  end
end
