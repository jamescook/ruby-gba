# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pathname"
require "stringio"
require "comparison_games"
require RubyGBA.root.join("examples/hero").to_s

# A CARTRIDGE THE FRAMEWORK DID NOT BUILD, played from a script: any cartridge file. What the
# build worked out about a cartridge — which variable is where, which sprite is which — is not
# in the file, so nothing in such a cartridge has a name. A script watches it by its pixels and
# by its memory.
#
# The cartridge here is the walker, built in the test and written to a file, which leaves its
# build record behind: a white box that walks two pixels a frame from column 20 while RIGHT is
# down. Nothing anybody else made is ever played.
class TestPlaythroughCartridgeFile < Minitest::Test
  runs_on :reference

  include ComparisonGames

  # The walker written to a file in a folder of its own. The block is handed the file's path
  # and the cartridge it was written from, which still knows where its variables are.
  private def with_walker_file
    Dir.mktmpdir("cartridges") do |folder|
      built = walker
      yield File.join(folder, "walker.gba").tap { |path| built.write(path) }, built
    end
  end

  # A CARTRIDGE FILE IS PLAYED FROM A SCRIPT THAT COUNTS FRAMES, given as its path, and its
  # moments fall on the frames the script says. The box is where twenty frames of RIGHT put
  # it, read off the screen.
  def test_a_cartridge_file_is_played_from_a_counted_script
    with_walker_file do |path, _built|
      at_the_moment = {}
      played = walk_right.play(path) do |moment, game|
        at_the_moment[moment] = (0...240).select { |x| game.white?(x, 60) }
      end

      assert_equal 60, played.frames
      assert_equal({ standing: 10, walked: 30 }, played.moments)
      assert_equal({ standing: (20..27).to_a, walked: (60..67).to_a }, at_the_moment)
    end
  end

  # A SCRIPT WATCHES SUCH A CARTRIDGE BY ITS PIXELS AND BY ITS MEMORY, and each wait ends on
  # the frame it should: the box reaches column 60 on frame 30, twenty frames of RIGHT after
  # ten of standing. Where the game keeps the box's column is known here only because the
  # test built the game; somebody watching a cartridge they did not build finds the address
  # some other way, and reads it the same.
  def test_a_wait_that_reads_a_pixel_or_memory_ends_on_the_right_frame
    with_walker_file do |path, built|
      column_at = built.var_addresses.fetch(:x)
      by_pixel = RubyGBA.playthrough "walk until the box is seen at column 60" do
        wait frames: 10
        hold_until("the box is at column 60", :right) { |game| game.white?(60, 60) && game.blue?(59, 60) }
        moment :there
      end
      by_memory = RubyGBA.playthrough "walk until memory says column 60" do
        wait frames: 10
        hold_until("the column in memory is 60", :right) { |game| game.mem32(column_at) >= 60 }
        moment :there
      end

      assert_equal 30, by_pixel.play(path).moments[:there]
      assert_equal 30, by_memory.play(path).moments[:there]
    end
  end

  # A plain wait watches such a cartridge too: until its first picture is up, which is the
  # frame the ground first shows blue when the cartridge is played on its own.
  def test_a_wait_until_reads_the_screen_of_a_cartridge_file
    with_walker_file do |path, built|
      picture_up = RubyGBA.playthrough "wait for the first picture" do
        wait_until("the ground is blue") { |game| game.blue?(0, 0) }
        moment :up
      end
      blue_on = first_frame(built, walk_right.play(built).tape) { |game| game.blue?(0, 0) }

      assert_equal blue_on, picture_up.play(path).moments[:up]
    end
  end

  # NOTHING IN SUCH A CARTRIDGE HAS A NAME, so asking for a variable or a sprite by one is a
  # friendly error: it says the cartridge was not built here, and what to read instead. It
  # does not tell somebody with a cartridge file how to assemble one.
  def test_asking_such_a_cartridge_for_a_name_says_why_and_what_to_read
    with_walker_file do |path, _built|
      game = walk_right.play(path).game
      [-> { game.var(:x) }, -> { game.sprites(:box) }, -> { game.sprites }].each do |asking|
        err = assert_raises(ArgumentError) { asking.call }

        assert_match(/not built here/, err.message)
        assert_match(/mem32/, err.message)
        assert_match(/pixel_gba/, err.message)
        refute_match(/ROM\.assemble/, err.message)
      end
    end
  end

  # A cartridge assembled HERE from machine code, with no record handed over, plays too and
  # has no names either — but that one is a slip, and is told how to put it right.
  def test_a_cartridge_assembled_with_no_build_record_plays_and_says_how_to_get_one
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :red
      game_loop {}
    end
    builder.finalize_program
    bare = ROM.assemble(GBA.new.lower(builder.program), title: "BARE")
    played = RubyGBA.playthrough("wait") { wait frames: 10 }.play(bare)
    err = assert_raises(ArgumentError) { played.game.var(:anything) }

    assert played.game.red?(120, 80)
    assert_match(/without its build record/, err.message)
    assert_match(/build_record/, err.message)
  end

  # A SAVE OF A SIZE THIS FRAMEWORK'S CARTRIDGES NEVER HAVE is one a cartridge somebody else
  # made can have. It is kept as its bytes, so such a cartridge can be started from it, and
  # a playthrough of one ends with the save handed back and not with an error about its size.
  def test_a_save_of_a_size_of_its_own_is_kept_as_its_bytes
    with_walker_file do |path, _built|
      half_a_kilobyte = File.join(File.dirname(path), "small.sav").tap { |written| File.binwrite(written, "\x07".b * 512) }
      played = walk_right.play(path, save: half_a_kilobyte)

      assert_equal "\x07".b * 512, played.save.to_sav
      assert_equal 512, File.size(played.save.write_sav(File.join(File.dirname(path), "back.sav")))
      assert_equal played.save.to_sav, walk_right.play(path, save: played.save).save.to_sav, "and it starts another"
    end
  end

  # A CARTRIDGE FILE SAVES AND STARTS FROM A SAVE LIKE ANY OTHER, and nothing is written
  # beside it: an emulator left to itself would put a save file there, and the next playing
  # would start in it. The hero example saves a walk of twelve steps; started again from
  # what came back, its file screen holds twelve, read from memory at the address the build
  # gave that number.
  def test_a_cartridge_file_saves_and_leaves_nothing_beside_it
    built = Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    saving = RubyGBA.playthrough "hero: walk twelve steps and save" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      hold :right, frames: 12
      press :start
      wait frames: 30
    end
    file_screen = RubyGBA.playthrough("hero: the file screen") { wait frames: 20 }

    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "hero.gba").tap { |written| built.write(written) }
      saved = saving.play(path).save
      shown = file_screen.play(path, save: saved).game.mem32(built.var_addresses.fetch(:shown0))

      assert_equal 12, shown
      assert_equal ["hero.gba"], Dir.children(folder)
    end
  end

  # The path can be a Pathname, and the tape of a playing says the same of a cartridge file
  # as it does of the cartridge the file was written from: its title, and a checksum of its
  # bytes.
  def test_a_cartridge_file_and_the_cartridge_it_was_written_from_make_the_same_tape
    with_walker_file do |path, built|
      assert_equal walk_right.play(built).tape, walk_right.play(Pathname(path)).tape
    end
  end

  # NOTHING IS WRITTEN BESIDE THE CARTRIDGE FILE, a save file least of all. An emulator left
  # to itself writes one there, and the next playing would start in it; here the folder
  # holds the cartridge and nothing else afterwards.
  def test_nothing_is_left_beside_a_cartridge_file_that_was_played
    with_walker_file do |path, _built|
      walk_right.play(path)

      assert_equal ["walker.gba"], Dir.children(File.dirname(path))
    end
  end

  # TWO CARTRIDGE FILES ARE COMPARED AS TWO BUILT CARTRIDGES ARE: no drift between a file and
  # itself, and a quicker walker's file drifts from the first frame its box has moved.
  def test_two_cartridge_files_are_compared
    with_walker_file do |path, built|
      fast = File.join(File.dirname(path), "fast.gba").tap { |written| walker(speed: 3).write(written) }
      moved_on = first_frame(built, walk_right.play(built).tape) { |game| !game.white?(20, 60) }

      refute walk_right.compare(path, path).drift?
      assert_equal moved_on, walk_right.compare(path, fast).drift.frame
    end
  end

  # --- what is not a cartridge, each refused before anything is played ---

  def test_a_cartridge_file_that_is_not_there_is_refused
    err = assert_raises(ArgumentError) { walk_right.play("no/such/game.gba") }

    assert_match(%r{no/such/game\.gba}, err.message)
    assert_match(/no cartridge file/, err.message)
  end

  # THE SECOND CARTRIDGE OF A COMPARISON IS LOOKED AT BEFORE THE FIRST IS PLAYED. This script
  # gives up on its first wait, so had it been played before the missing file was noticed,
  # that is the error there would be.
  def test_a_second_cartridge_that_is_not_there_is_refused_before_the_first_is_played
    never = RubyGBA.playthrough("wait for what never comes") { wait_until("never", within: 1) { |_game| false } }
    with_walker_file do |path, _built|
      err = assert_raises(ArgumentError) { never.compare(path, "no/such/other.gba") }

      assert_match(/other\.gba/, err.message)
    end
  end

  # The bytes of a cartridge are not its path. Handed over by mistake they are named for
  # what they are, and not printed.
  def test_the_bytes_of_a_cartridge_given_as_its_path_are_refused
    built = walker
    err = assert_raises(ArgumentError) { walk_right.play(built.buffer) }

    assert_match(/#{built.buffer.bytesize} bytes/, err.message)
    assert_match(/path of a cartridge file/, err.message)
    assert_operator err.message.length, :<, 400
  end

  # A file that is not a cartridge — a tape, an empty file, and a long file of nothing — is
  # told from one.
  def test_a_file_that_is_not_a_cartridge_is_refused
    with_walker_file do |path, built|
      folder = File.dirname(path)
      tape = walk_right.play(built).tape.write(File.join(folder, "walk.tape"))
      empty = File.join(folder, "empty.gba").tap { |written| File.write(written, "") }
      blank = File.join(folder, "blank.gba").tap { |written| File.binwrite(written, "\0".b * 4096) }

      [tape, empty, blank].each do |wrong|
        err = assert_raises(ArgumentError) { walk_right.play(wrong) }

        assert_match(/#{File.basename(wrong)}/, err.message)
        assert_match(/not a cartridge/, err.message)
      end
    end
  end

  def test_something_that_is_neither_a_cartridge_nor_a_path_is_refused
    [nil, 42, :walker, ""].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.play(wrong) }

      assert_match(/cartridge the build made/, err.message)
      assert_match(/path of a cartridge file/, err.message)
    end
  end
end
