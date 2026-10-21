# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "cli_playing"
require "png_reading"

# `ruby-gba play`: a game played from the command line with nobody at the controls, by a
# script or by a tape, saying how many frames went by and where each moment fell, and
# writing what was asked for: pictures, the tape, the save memory.
class TestCommandLinePlay < Minitest::Test
  include CLIPlaying
  include PNGReading

  BLUE = [0, 0, 255].freeze
  WHITE = [255, 255, 255].freeze

  # THE PLAY COMMAND ON A GAME FILE AND A SCRIPT says what was played, and writes the
  # pictures, the tape and the save memory where it is told. The picture at :walked shows
  # the box twenty frames of two pixels on from where it began.
  def test_play_says_the_frames_and_the_moments_and_writes_what_it_is_told
    with_game_and_scripts do |dir|
      out, status = cli("play", "walker.rb", "--script", "walk.rb", "--pictures-in", "pictures",
                        "--write-tape", "walk.tape", "--write-save", "walk.sav", dir: dir)
      walked = png_pixels(File.binread(File.join(dir, "pictures", "walked.png")))

      assert status.success?, out
      assert_match(/Played 60 frames of "walk" on WALKER\./, out)
      assert_match(/standing +frame 10$/, out)
      assert_match(/walked +frame 30$/, out)
      assert_equal %w[standing.png walked.png], Dir.children(File.join(dir, "pictures")).sort
      assert_equal [BLUE, WHITE], [walked[(60 * 240) + 59], walked[(60 * 240) + 60]], "the box's left edge is at 60"
      assert_equal ["10 -", "moment standing", "20 right", "moment walked", "30 -"], File.readlines(File.join(dir, "walk.tape"), chomp: true).drop(4)
      assert_equal 32 * 1024, File.size(File.join(dir, "walk.sav")), "the walker's save memory, whole"
    end
  end

  # A CARTRIDGE FILE IN PLACE OF A GAME FILE, AND A TAPE IN PLACE OF A SCRIPT: the tape the
  # script made, played on the cartridge the game file builds, is the same sixty frames and
  # the same two moments.
  def test_play_takes_a_cartridge_file_and_a_tape
    with_game_and_scripts do |dir|
      cli("build", "walker.rb", "-o", "walker.gba", dir: dir)
      cli("play", "walker.rb", "--script", "walk.rb", "--write-tape", "walk.tape", dir: dir)

      out, status = cli("play", "walker.gba", "--tape", "walk.tape", dir: dir)

      assert status.success?, out
      assert_match(/Played 60 frames of the tape walk\.tape on WALKER\./, out)
      assert_match(/standing +frame 10$/, out)
      assert_match(/walked +frame 30$/, out)
    end
  end

  # A GAME BOY COLOR CARTRIDGE FILE plays the same way: the script's frames and moments, said
  # under the title the Color's own header holds.
  COLOR_WALKER = <<~RUBY
    require "ruby_gba"

    RubyGBA.game "COLOR WALKER", consoles: %i[gba gbc] do
      screen :tiled
      image(:box, "#" => :white) { "########\\n" * 8 }
      x = var :x, 20
      box = sprite :box, at: [x, 60]
      game_loop do
        held(:right).then { x.add! 2 }
        box.move_to x, 60
      end
    end
  RUBY

  def test_play_takes_a_game_boy_color_cartridge_file
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "color_walker.rb"), COLOR_WALKER)
      built, = cli("build", "color_walker.rb", "--console", "gbc", dir: dir)

      out, status = cli("play", "color_walker.gbc", "--script", "walk.rb", dir: dir)

      assert status.success?, "#{built}\n#{out}"
      assert_match(/Played 60 frames of "walk" on COLOR WALKE\./, out)
      assert_match(/walked +frame 30$/, out)
    end
  end

  # A GAME FILE PLAYED AS ITS COLOR CARTRIDGE, with --console gbc. Built here, its variables
  # have their names, so a script can wait on one: the box walks from 20 to 60 at two pixels a
  # frame, which is twenty frames of RIGHT after the ten of standing.
  def test_play_with_console_gbc_builds_the_color_cartridge_of_a_game_file
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "color_walker.rb"), COLOR_WALKER)

      out, status = cli("play", "color_walker.rb", "--console", "gbc", "--script", "several.rb",
                        "--playthrough", "walk to sixty", dir: dir)

      assert status.success?, out
      assert_match(/on COLOR WALKE\./, out)
      assert_match(/arrived +frame 30$/, out)
    end
  end

  # A playing plays one cartridge, so a game file for two consoles is asked which.
  def test_play_asks_which_console_for_a_game_file_of_two
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "color_walker.rb"), COLOR_WALKER)

      out, status = cli("play", "color_walker.rb", "--script", "walk.rb", dir: dir)

      refute status.success?
      assert_match(/COLOR WALKER is for the Game Boy Advance and the Game Boy Color/, out)
      assert_match(/--console gba or --console gbc/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # A game file the Color's build refuses is refused in the build's words, as `build` says it.
  def test_play_with_console_gbc_says_a_refused_build_plainly
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "again.rb"), <<~RUBY)
        require "ruby_gba"
        RubyGBA.game("AGAIN", consoles: %i[gba gbc]) do
          func(:again) { call :again }
          game_loop { call :again }
        end
      RUBY

      out, status = cli("play", "again.rb", "--console", "gbc", "--script", "walk.rb", dir: dir)

      refute status.success?
      assert_match(/can call itself again/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # --set REACHES THE GAME FILE. The walk to sixty is forty pixels: twenty frames of
  # holding RIGHT at the game's two a frame, and ten at four.
  def test_set_builds_the_game_file_with_a_setting
    with_game_and_scripts do |dir|
      to_sixty = ["play", "walker.rb", "--script", "several.rb", "--playthrough", "walk to sixty"]

      as_written, = cli(*to_sixty, dir: dir)
      quick, status = cli(*to_sixty, "--set", "speed=4", dir: dir)

      assert status.success?, quick
      assert_match(/arrived +frame 30$/, as_written)
      assert_match(/arrived +frame 20$/, quick)
    end
  end

  # A SAVE TO START FROM. The walker keeps the furthest it has walked in its save memory.
  # A playing that only stands, started from the save a walk left, leaves that save as it
  # was; started from power-on, it leaves the save of a walker that has not walked.
  def test_play_starts_from_a_save
    with_game_and_scripts do |dir|
      cli("play", "walker.rb", "--script", "walk.rb", "--write-save", "walked.sav", dir: dir)
      stand = ["play", "walker.rb", "--script", "several.rb", "--playthrough", "stand"]

      out, status = cli(*stand, "--save", "walked.sav", "--write-save", "kept.sav", dir: dir)
      cli(*stand, "--write-save", "fresh.sav", dir: dir)
      walked, kept, fresh = %w[walked kept fresh].map { |name| File.binread(File.join(dir, "#{name}.sav")) }

      assert status.success?, out
      assert_equal walked, kept, "from the save, the furthest walked is still the walk's"
      refute_equal walked, fresh, "from power-on, it is where a walker starts"
    end
  end

  # A LEAD-IN, named from the script file, is played first and not counted: five frames of
  # one before twelve of standing is still twelve frames played, and the tape says it
  # starts after a lead-in.
  def test_play_plays_a_lead_in_first_and_does_not_count_it
    with_game_and_scripts do |dir|
      out, status = cli("play", "walker.rb", "--script", "several.rb", "--playthrough", "stand",
                        "--lead-in", "five frames", "--write-tape", "stand.tape", dir: dir)

      assert status.success?, out
      assert_match(/Played 12 frames of "stand" on WALKER\./, out)
      assert_equal "starts from: power-on after a lead-in", File.readlines(File.join(dir, "stand.tape"), chomp: true)[2]
    end
  end

  # A TAPE RECORDED AFTER A LEAD-IN needs the lead-in again, and the lead-in is declared in
  # a script file: each thing missing is asked for by its flag, and with both the tape
  # plays its twelve frames.
  def test_a_tape_recorded_after_a_lead_in_asks_for_it_by_its_flag
    with_game_and_scripts do |dir|
      cli("play", "walker.rb", "--script", "several.rb", "--playthrough", "stand", "--lead-in", "five frames",
          "--write-tape", "led-in.tape", dir: dir)
      on_the_tape = ["play", "walker.rb", "--tape", "led-in.tape"]

      no_lead_in, without = cli(*on_the_tape, dir: dir)
      no_script, without_a_script = cli(*on_the_tape, "--lead-in", "five frames", dir: dir)
      out, with = cli(*on_the_tape, "--lead-in", "five frames", "--script", "several.rb", dir: dir)

      refute without.success?
      assert_match(/recorded after a lead-in.*--lead-in.*--script/, no_lead_in)
      refute without_a_script.success?
      assert_match(/no script file was given.*--script/, no_script)
      assert with.success?, out
      assert_match(/Played 12 frames of the tape led-in\.tape on WALKER\./, out)
    end
  end

  # --- what it needs to be told ---

  # A SCRIPT FILE WITH SEVERAL PLAYTHROUGHS AND NONE PICKED is refused, listing them. So is
  # a name it does not declare.
  def test_several_playthroughs_and_none_picked_lists_them
    with_game_and_scripts do |dir|
      [[], ["--playthrough", "run"]].each do |picked|
        out, status = cli("play", "walker.rb", "--script", "several.rb", *picked, dir: dir)

        refute status.success?
        assert_match(/"stand", "walk to sixty", "five frames"/, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # A PLAYTHROUGH NAMED WITH A SYMBOL is picked by the same letters, since a command line
  # can only give text.
  def test_a_playthrough_named_with_a_symbol_is_picked_by_its_letters
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "symbols.rb"), <<~RUBY)
        RubyGBA.playthrough(:stroll) { wait frames: 3 }
        RubyGBA.playthrough(:amble) { wait frames: 7 }
      RUBY

      out, status = cli("play", "walker.rb", "--script", "symbols.rb", "--playthrough", "amble", dir: dir)

      assert status.success?, out
      assert_match(/Played 7 frames of "amble" on WALKER\./, out)
    end
  end

  # What is wrong is said before the game file is built, in plain words and with no
  # backtrace. The last two are places to write to that cannot be: they are refused before
  # a frame is played, since the tape and the save are written after the last one.
  def test_what_cannot_be_played_is_said_plainly
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "empty.rb"), "# no playthrough here\n")
      {
        ["walker.rb"] => /--script.*--tape/,
        ["walker.rb", "--script", "nope.rb"] => /cannot find the script file nope\.rb/,
        ["walker.rb", "--script", "empty.rb"] => /does not declare a playthrough/,
        ["nope.gba", "--script", "walk.rb"] => /cannot find nope\.gba/,
        ["walker.rb", "--script", "walk.rb", "--save", "nope.sav"] => /no save file at nope\.sav/,
        ["walker.rb", "--script", "walk.rb", "--lead-in", "nobody"] => /no playthrough named "nobody"/,
        ["walker.rb", "--script", "walk.rb", "--write-tape", "nowhere/walk.tape"] => /--write-tape nowhere\/walk\.tape cannot be written/,
        ["walker.rb", "--script", "walk.rb", "--write-save", "."] => /--write-save \. is a folder/,
      }.each do |args, says|
        out, status = cli("play", *args, dir: dir)

        refute status.success?, args.inspect
        assert_match(says, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # A wait that never ends stops the command with the playthrough's own words for it.
  def test_a_script_that_gives_up_says_so_and_fails
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "never.rb"), <<~RUBY)
        RubyGBA.playthrough "never" do
          wait_until("the box is at ninety", within: 5) { |game| game.var(:x) >= 90 }
        end
      RUBY

      out, status = cli("play", "walker.rb", "--script", "never.rb", dir: dir)

      refute status.success?
      assert_match(/waited until the box is at ninety/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # THE BUILT-IN HELP describes the command.
  def test_help_describes_play
    with_game_and_scripts do |dir|
      list, = cli("help", dir: dir)
      help, = cli("help", "play", dir: dir)

      assert_match(/play CARTRIDGE/, list)
      %w[--script --playthrough --tape --save --lead-in --pictures-in --write-tape --write-save --set].each { |option| assert_includes help, option }
    end
  end
end
