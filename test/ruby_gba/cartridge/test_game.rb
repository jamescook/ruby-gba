# frozen_string_literal: true

require "test_helper"

require "stringio"

# RubyGBA.game declares a game (title + codes + DSL block) without building or
# writing it, and hands back a handle. The handle is what the reference interpreter
# and the ROM build run against (#program / #build_rom), and what the `ruby-gba`
# command loads. These assert the handle behaves, and that just declaring a game is
# side-effect free (no cartridge written) so tests and the CLI stay in control.
class TestGame < Minitest::Test

  def test_it_returns_a_handle_carrying_the_title_and_codes
    g = RubyGBA.game("MYGAME", code: "BMYG", maker: "01") { screen :bitmap }
    assert_equal "MYGAME", g.title
    assert_equal "BMYG", g.code
    assert_equal "01", g.maker
  end

  def test_program_runs_on_the_interpreter
    g = RubyGBA.game("FILL", code: "BFIL", maker: "01") do
      screen :bitmap
      clear_screen :red
      halt
    end
    i = Reference.new.run(g.program)
    assert_equal Color.resolve(:red), i.screen.pixel(10, 10)
  end

  # The DSL block is later instance_eval'd on a Builder, which changes self but not
  # the block's own local-variable closure. Migrated examples lean on this to keep
  # their build-time values as plain locals, so prove a captured local reaches the
  # program.
  def test_a_local_variable_is_captured_by_the_block
    fill = :green
    g = RubyGBA.game("LOCAL", code: "BLOC", maker: "01") do
      screen :bitmap
      clear_screen fill
      halt
    end
    i = Reference.new.run(g.program)
    assert_equal Color.resolve(:green), i.screen.pixel(0, 0)
  end

  def test_build_rom_returns_a_written_cartridge
    g = RubyGBA.game("ROMTEST", code: "BRMT", maker: "01") do
      screen :bitmap
      clear_screen :blue
      halt
    end
    rom = g.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0
    refute rom.compression.any?, "a plain bitmap packs nothing"
  end

  def test_declaring_a_game_registers_it
    before = RubyGBA.registered_games.length
    g = RubyGBA.game("REG", code: "BREG", maker: "01") { screen :bitmap }
    assert_equal g, RubyGBA.registered_games.last
    assert_equal before + 1, RubyGBA.registered_games.length
  end

  def test_default_filename_from_the_title
    g = RubyGBA.game("Space Blast!", code: "BSPB", maker: "01") { screen :bitmap }
    assert_equal "space_blast.gba", g.default_filename
  end

  def test_a_block_is_required
    err = assert_raises(ArgumentError) { RubyGBA.game("NOBLOCK", code: "BNOB", maker: "01") }
    assert_match(/needs a block/, err.message)
  end

  # Declaring a game writes nothing on its own — building/writing is the caller's
  # choice. write_if_main only acts when the calling file is the script Ruby was run
  # with, so a required/loaded file (a test, or the `ruby-gba` command) stays silent.
  def test_declaring_a_game_writes_nothing
    out, = capture_io do
      RubyGBA.game("QUIET", code: "BQUI", maker: "01") do
        screen :bitmap
        halt
      end
    end
    assert_empty out
  end

  def test_main_script_guard_matches_only_the_running_script
    g = RubyGBA.game("GUARD", code: "BGRD", maker: "01") { screen :bitmap }
    refute g.send(:main_script?, "/nowhere/not_the_runner.rb"), "a foreign file is not the main script"
    assert g.send(:main_script?, $PROGRAM_NAME), "the running script matches itself"
  end
end
