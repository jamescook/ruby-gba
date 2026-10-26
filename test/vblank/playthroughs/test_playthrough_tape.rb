# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "zlib"
require VBlank.root.join("examples/hero").to_s

# A TAPE: THE PRESSES OF A PLAYTHROUGH, WRITTEN DOWN. A script says what to do; a tape says
# what was done — which buttons were down on each frame, and the frame each named moment fell
# on. Playing a script makes one, and any cartridge can be fed one in place of a script, which
# is what lets two cartridges be given exactly the same presses on exactly the same frames.
class TestPlaythroughTape < Minitest::Test
  Tape = VBlank::Playthroughs::Tape

  # A game that ticks once a frame, moves two pixels across for every frame RIGHT is down, and
  # counts presses of A. Its first tick is on its second frame: the first frame is the
  # cartridge setting itself up.
  private def ticking_game(title = "TICKING")
    VBlank.build(title, console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      x = var :x, 0
      taps = var :taps, 0
      game_loop do
        ticks.add! 1
        held(:right).then { x.add! 2 }
        pressed(:a).then { taps.add! 1 }
      end
    end
  end

  private def hero_cartridge = Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false)

  private def walk_out_of_the_file_screen
    VBlank.playthrough "hero: third file, new game, walk right" do
      wait frames: 10
      press :down
      press :down
      press :a
      wait frames: 4
      moment :file_picked
      press :a
      wait frames: 4
      moment :standing
      hold :right, :up, frames: 20
      wait frames: 4
      moment :walked
    end
  end

  # What a playing showed and counted at each of its moments.
  private def seen_while(cartridge, played_by)
    {}.tap do |seen|
      seen[:played] = played_by.play(cartridge) do |moment, game|
        seen[moment] = [game.frame_gba, game.var(:px), game.var(:py), game.var(:steps)]
      end
    end
  end

  # THE TAPE PLAYS THE GAME THE SCRIPT PLAYED: the same moments on the same frames, and at
  # each the same picture and the same numbers.
  def test_a_tape_plays_back_what_the_script_played
    cartridge = hero_cartridge
    from_script = seen_while(cartridge, walk_out_of_the_file_screen)
    from_tape = seen_while(cartridge, from_script[:played].tape)

    assert_equal({ file_picked: 20, standing: 26, walked: 50 }, from_tape[:played].moments)
    assert_equal from_script[:played].frames, from_tape[:played].frames
    %i[file_picked standing walked].each do |moment|
      assert_equal from_script[moment].drop(1), from_tape[moment].drop(1), "the numbers at #{moment}"
      assert from_script[moment][0] == from_tape[moment][0], "the picture at #{moment}"
    end
    assert_equal Hero::START_X + 40, from_tape[:walked][1], "and it did walk"
  end

  # ...ON EVERY FRAME, not only at the ones somebody thought to name. A script that names each
  # of thirty frames of walking gives a tape that names them too, and the picture on every one
  # of them is the picture the script showed.
  def test_a_tape_shows_the_same_picture_on_every_frame
    every_frame = VBlank.playthrough "hero: every frame of a walk" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      30.times do |frame|
        hold :right, frames: 1
        moment :"walking_#{frame}"
      end
    end
    cartridge = hero_cartridge
    from_script = seen_while(cartridge, every_frame)
    from_tape = seen_while(cartridge, from_script[:played].tape)
    differing = (0...30).reject { |frame| from_script[:"walking_#{frame}"] == from_tape[:"walking_#{frame}"] }

    assert_empty differing, "frames whose picture or numbers differed"
    refute_equal from_script[:walking_0][0], from_script[:walking_29][0], "and the picture did change as he walked"
  end

  # THE TEXT OF A TAPE, whole: what it is, what it was recorded on, where it started, then a
  # line for each stretch of frames with the same buttons down and a line for each moment.
  # A hold of twenty frames is one line, and so are two waits that run on from each other.
  # The checksum is of the cartridge's own bytes, as a file of it holds them.
  def test_a_tape_is_text_a_person_can_read
    script = VBlank.playthrough "a little of everything" do
      wait frames: 4
      wait frames: 6
      press :a
      hold :up, :right, frames: 20
      moment :walked
      wait frames: 3
    end
    cartridge = ticking_game
    text = script.play(cartridge).tape.to_s
    checksum = Dir.mktmpdir do |dir|
      cartridge.write(File.join(dir, "ticking.gba"))
      Zlib.crc32(File.binread(File.join(dir, "ticking.gba")))
    end

    assert_equal ["vblank tape 1", format("recorded on: TICKING 0x%08X", checksum), "starts from: power-on", ""],
                 text.lines(chomp: true).first(4)
    assert_equal ["10 -", "1 a", "1 -", "20 right up", "moment walked", "3 -"], text.lines(chomp: true).drop(4)
  end

  # A SCRIPT THAT WATCHED THE GAME LEAVES A TAPE THAT ONLY COUNTS: what is written down is the
  # frames the wait turned out to be. The game's first tick is on its second frame, so it has
  # ticked fifty times on frame 51: five frames waited, then forty-six with RIGHT down. The
  # tape needs nothing to watch, and played again it stops where the script stopped.
  def test_a_watching_script_records_the_frames_it_turned_out_to_take
    script = VBlank.playthrough "walk until fifty ticks" do
      wait frames: 5
      hold_until("the game has ticked fifty times", :right) { |game| game.var(:ticks) >= 50 }
      moment :fifty
    end
    cartridge = ticking_game
    played = script.play(cartridge)
    again = {}
    played.tape.play(cartridge) { |name, game| again[name] = [game.var(:ticks), game.var(:x)] }

    assert_equal ["5 -", "46 right", "moment fifty"], played.tape.to_s.lines(chomp: true).drop(4)
    assert_equal({ fifty: [50, 92] }, again)
  end

  # Written to a file and read back, it is the same tape: the same lines, the same moments,
  # and the same thing said about where it came from.
  def test_a_tape_written_to_a_file_reads_back_the_same
    tape = walk_out_of_the_file_screen.play(hero_cartridge).tape
    Dir.mktmpdir do |dir|
      path = tape.write(File.join(dir, "walk.tape"))
      back = Tape.read(path)

      assert_equal tape, back
      assert_equal File.read(path), back.to_s
      assert_equal({ file_picked: 20, standing: 26, walked: 50 }, back.moments)
      assert_equal 50, back.frames
      assert_equal %w[HERO power-on], [back.title, back.starts_from]
    end
  end

  # A TITLE IS WHATEVER BYTES THE CARTRIDGE'S HEADER HOLDS, and a cartridge somebody else made
  # can hold anything there. On a tape it is a line for a person to read, so what cannot be
  # printed is written as `?` — and the tape still reads back as itself.
  def test_a_cartridge_title_that_cannot_be_printed_still_makes_a_tape_that_reads_back
    cartridge = ticking_game
    cartridge.patch(VBlank::Cartridge::Header::HEADER_TITLE, "AB\xFFC\nD".b.ljust(12, "\0"))
    tape = VBlank.playthrough("one frame") { wait frames: 1 }.play(cartridge).tape

    assert_equal "AB?C?D", tape.title
    assert_equal tape, Tape.parse(tape.to_s)
  end

  # A TAPE RECORDED ON ONE CARTRIDGE PLAYS ON ANOTHER, which is the point of one. What it says
  # it was recorded on is for a person to read, and nothing holds the tape to it.
  def test_a_tape_recorded_on_one_cartridge_plays_on_another
    script = VBlank.playthrough "walk" do
      wait frames: 10
      hold :right, frames: 20
      wait frames: 2
    end
    tape = script.play(ticking_game("FIRST")).tape
    other = tape.play(ticking_game("SECOND"))

    assert_equal "FIRST", tape.title
    assert_equal 40, other.game.var(:x)
    assert_equal 32, other.frames
    assert_equal "SECOND", other.tape.title, "and the tape of that playing says what IT was played on"
    assert_equal tape.steps, other.tape.steps, "...with the same presses on it"
  end

  # A tape somebody wrote by hand plays like any other. Below the three lines of its heading,
  # blank lines and lines that start with `#` are for the person reading it, a line can be set
  # in from the edge, and two lines that say the same buttons run together as one.
  def test_a_tape_written_by_hand_can_be_played
    tape = Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: ANYTHING 0x00000000
      starts from: power-on

      # let the game start, then two taps
      6 -
      4 -
        1 a
        1 -
        1 a
        1 -
          # both seen by now
      moment tapped_twice
      4 -
    TAPE
    taps = nil
    played = tape.play(ticking_game) { |name, game| taps = [name, game.var(:taps)] }

    assert_equal [:tapped_twice, 2], taps
    assert_equal({ tapped_twice: 14 }, tape.moments)
    assert_equal tape.steps, played.tape.steps, "and it is the tape its own playing makes"
  end

  # A TAPE CUT AT A FRAME IS THE SAME PRESSES UP TO THAT FRAME AND NO FURTHER, which is how a
  # frame part way through is got back to. A hold the frame falls inside is cut short. A
  # moment is kept when the frame it names is still on the tape — the very last frame
  # included — and dropped when it is not.
  def test_a_tape_cut_at_a_frame_ends_on_it_and_keeps_the_moments_before
    tape = Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: ANYTHING 0x00000000
      starts from: power-on

      10 -
      moment settled
      20 right
      moment walked
      5 -
    TAPE
    cut = ->(frame) { tape.up_to(frame).to_s.lines.drop(4).map(&:chomp) }

    assert_equal ["10 -", "moment settled", "5 right"], cut.call(15), "cut inside the hold, and :walked is past it"
    assert_equal ["10 -", "moment settled", "20 right", "moment walked"], cut.call(30), "the moment on the last frame stays"
    assert_equal ["10 -", "moment settled"], cut.call(10)
    assert_equal ["4 -"], cut.call(4)
    assert_equal tape, tape.up_to(35)
    assert_equal tape, tape.up_to(1000), "a frame past the end is the whole tape"
    assert_equal tape.to_s.lines.first(3), tape.up_to(4).to_s.lines.first(3), "its heading is still that tape's"
  end

  # Cut at frame 15, it plays to frame 15: the game has ticked as often as on the whole tape
  # at that frame.
  def test_a_tape_cut_at_a_frame_plays_to_that_frame
    game = ticking_game
    whole = VBlank.playthrough("wait") { wait frames: 40 }.play(game).tape
    ticks_after = ->(tape) { tape.play(game).game.var(:ticks) }

    assert_equal 15, whole.up_to(15).frames
    assert_equal 25, ticks_after.call(whole) - ticks_after.call(whole.up_to(15)), "twenty-five frames fewer, twenty-five ticks fewer"
  end

  # WHAT WAS DOWN ON A RANGE OF FRAMES, a stretch for each run with the same buttons down. A
  # moment between two lines of the same buttons is no frames long, so it does not split a
  # run; and a run that starts before the range or ends after it is cut to the range.
  def test_a_tape_says_what_was_down_on_a_range_of_frames
    tape = Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: ANYTHING 0x00000000
      starts from: power-on

      10 -
      moment settled
      5 -
      20 right up
      1 a
      4 -
    TAPE
    down_on = ->(frames) { tape.presses_within(frames).map { |stretch| [stretch.frames, stretch.buttons] } }

    assert_equal [[1..15, []], [16..35, %i[right up]], [36..36, [:a]], [37..40, []]], down_on.call(1..40)
    assert_equal [[12..15, []], [16..20, %i[right up]]], down_on.call(12..20), "cut at both ends"
    assert_equal [[36..36, [:a]]], down_on.call(36..36)
    assert_equal [[37..40, []]], down_on.call(37..500), "a range that runs past the end stops where the tape does"
  end

  def test_a_tape_cut_before_its_first_frame_is_refused
    tape = VBlank.playthrough("one frame") { wait frames: 1 }.play(ticking_game).tape
    [0, -3, 1.5, nil].each do |wrong|
      err = assert_raises(ArgumentError) { tape.up_to(wrong) }

      assert_match(/counted from 1/, err.message)
    end
  end

  # A tape holds nothing but names and numbers, so every core can read one: it can be kept in
  # a constant of a test, where a script with a watching step cannot.
  def test_a_tape_can_be_shared_between_cores
    tape = VBlank.playthrough("one frame") { wait frames: 1 }.play(ticking_game).tape

    assert Ractor.shareable?(tape)
    assert Ractor.shareable?(Tape.parse(tape.to_s))
  end

  # --- a moment's name is a plain one, in a script and on a tape ---

  # A name is written on a tape as a word, so it has to be one: letters, digits and
  # underscores. Anything else would not come back as itself.
  def test_a_moment_name_that_is_not_a_plain_name_is_refused_in_a_script
    ["door", 3, :"at the door", :"", :"1st"].each do |wrong|
      err = assert_raises(ArgumentError) do
        VBlank.playthrough "names" do
          wait frames: 1
          moment wrong
        end
      end

      assert_match(/#{Regexp.escape(wrong.inspect)}/, err.message)
      assert_match(/like :at_the_door/, err.message)
    end
  end

  # --- a file that cannot be read says which line, and what a line there looks like ---

  private def unreadable(body, heading: "vblank tape 1\nrecorded on: X 0x00000000\nstarts from: power-on\n")
    assert_raises(ArgumentError) { Tape.parse("#{heading}#{body}", from: "walk.tape") }.message
  end

  def test_a_line_that_cannot_be_read_is_named_with_what_is_on_it
    no_count = unreadable("10 -\nright 20\n")
    no_buttons = unreadable("10\n")
    not_a_button = unreadable("10 -\n3 fire\n")
    zero = unreadable("0 -\n")
    dash_and_button = unreadable("3 - a\n")

    assert_match(/walk\.tape cannot be read at line 5: "right 20"/, no_count)
    assert_match(/how many frames/, no_count)
    assert_match(/line 4: "10"/, no_buttons)
    assert_match(/`-` for none/, no_buttons)
    assert_match(/line 5: "3 fire".*"fire" names a button the console does not have.*a, b, select/m, not_a_button)
    assert_match(/line 4: "0 -"/, zero)
    assert_match(/line 4: "3 - a".*`-` means no button/m, dash_and_button)
  end

  def test_a_moment_line_that_cannot_be_read_says_what_to_write
    too_soon = unreadable("moment start\n10 -\n")
    twice = unreadable("10 -\nmoment here\n5 -\nmoment here\n")
    no_name = unreadable("10 -\nmoment\n")
    two_words = unreadable("10 -\nmoment at the door\n")

    assert_match(/line 4: "moment start".*Put the moment after a line of frames/m, too_soon)
    assert_match(/line 7: "moment here".*already has a moment named here.*a different name/m, twice)
    assert_match(/line 5: "moment".*like `moment at_the_door`/m, no_name)
    assert_match(/line 5: "moment at the door".*like `moment at_the_door`/m, two_words)
  end

  def test_a_file_that_is_not_a_tape_or_has_no_heading_is_refused
    not_a_tape = unreadable("", heading: "#!/bin/sh\n")
    empty = unreadable("", heading: "")
    no_cartridge = unreadable("", heading: "vblank tape 1\n10 -\n")
    no_start = unreadable("", heading: "vblank tape 1\nrecorded on: X 0x00000000\n10 -\n")
    odd_start = unreadable("", heading: "vblank tape 1\nrecorded on: X 0x00000000\nstarts from: the moon\n")

    assert_match(%r{walk\.tape is not a tape.*Line 1 is "#!/bin/sh"}m, not_a_tape)
    assert_match(/walk\.tape is not a tape.*The file is empty/m, empty)
    assert_match(/line 2.*recorded on/m, no_cartridge)
    assert_match(/line 3.*starts from/m, no_start)
    assert_match(/line 3: "starts from: the moon".*power-on/m, odd_start)
  end

  def test_a_tape_file_that_is_not_there_is_refused_by_name
    err = assert_raises(ArgumentError) { Tape.read("/no/such/folder/walk.tape") }

    assert_match(%r{There is no tape file at /no/such/folder/walk\.tape}, err.message)
  end
end
