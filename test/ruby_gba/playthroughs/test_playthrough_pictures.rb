# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pathname"
require "comparison_games"
require "png_reading"

# THE PICTURES OF A PLAYTHROUGH: the screen at each named moment, handed back, and written to
# a folder as PNG files when asked. It is the half of driving a game with nobody at the
# controls that a person looks at.
#
# The game is the walker: a white box that stands at column 20 and, with RIGHT down for
# twenty frames, ends forty pixels on.
class TestPlaythroughPictures < Minitest::Test
  runs_on :reference

  include ComparisonGames
  include PNGReading

  WIDTH = 240

  private def colour_at(picture, x, y) = picture[(y * WIDTH) + x]

  # THE PICTURE AT A MOMENT IS THE SCREEN AS THE CONSOLE SHOWED IT ON THAT MOMENT'S FRAME.
  # The witness is a second console: the same cartridge played again, a frame at a time, on
  # the presses the first playing made, and read on the frame each moment fell on. The box
  # is where it is known to be on each, to the pixel: eight wide from column 20, and from
  # column 60 once it has walked.
  def test_the_picture_at_a_moment_is_the_screen_on_that_frame
    cartridge = walker
    played = walk_right.play(cartridge)
    on_frame = {}
    each_frame_of(cartridge, played.tape) { |game, frame| on_frame[frame] = game.frame_gba if played.moments.value?(frame) }
    white_columns = ->(picture) { (0...WIDTH).select { |x| colour_at(picture, x, 60) == Color.resolve(:white) } }

    assert_equal %i[standing walked], played.pictures.keys
    played.moments.each { |name, frame| assert played.pictures[name] == on_frame[frame], "the screen on frame #{frame}" }
    assert_equal (20..27).to_a, white_columns.call(played.pictures[:standing])
    assert_equal (60..67).to_a, white_columns.call(played.pictures[:walked])
  end

  # The walker shows two colours and no others, so its picture as a PNG is known in full:
  # white where the picture is white and blue everywhere else.
  private def png_colours_of(picture)
    picture.map { |colour| colour == Color.resolve(:white) ? [255, 255, 255] : [0, 0, 255] }
  end

  # ASKED TO, A PLAYTHROUGH WRITES ONE PNG FOR EACH MOMENT INTO A FOLDER, named for the
  # moment, and says where each went. The folder is made if it is not there. Each file is
  # read back by the format's own rules and is that moment's picture, every pixel of it.
  def test_asked_to_it_writes_a_png_for_each_moment_named_for_it
    Dir.mktmpdir("pictures") do |somewhere|
      folder = File.join(somewhere, "of", "the", "walk")
      played = walk_right.play(walker, pictures_in: folder)

      assert_equal({ standing: File.join(folder, "standing.png"), walked: File.join(folder, "walked.png") }, played.picture_files)
      assert_equal %w[standing.png walked.png], Dir.children(folder).sort
      played.pictures.each do |name, picture|
        png = File.binread(played.picture_files[name])

        assert_equal [Color.resolve(:blue), Color.resolve(:white)].sort, picture.uniq.sort, "the walker's two colours"
        assert_equal [240, 160], png_size(png)
        assert png_pixels(png) == png_colours_of(picture), "#{name}.png is the picture at :#{name}"
      end
    end
  end

  # Not asked to, it says it wrote no file. That it really wrote none — with a folder to
  # look in — is test_playthrough_writes_no_file.rb, which has to run on its own.
  def test_not_asked_to_it_says_no_file_was_written
    assert_empty walk_right.play(walker).picture_files
  end

  # The folder can be given as a Pathname, and can be there already.
  def test_the_folder_can_be_a_pathname_and_can_be_there_already
    Dir.mktmpdir("pictures") do |folder|
      walk_right.play(walker, pictures_in: Pathname(folder))

      assert_equal %w[standing.png walked.png], Dir.children(folder).sort
    end
  end

  # A tape writes its pictures the same way.
  def test_a_tape_writes_its_pictures_too
    Dir.mktmpdir("pictures") do |folder|
      cartridge = walker
      played = walk_right.play(cartridge).tape.play(cartridge, pictures_in: folder)

      assert_equal %w[standing.png walked.png], Dir.children(folder).sort
      assert_equal File.join(folder, "walked.png"), played.picture_files[:walked]
    end
  end

  # THE PICTURES ARE WRITTEN AS THE MOMENTS ARE REACHED, so a playthrough that gives up
  # further on leaves the pictures of how far it got.
  def test_a_playthrough_that_gives_up_leaves_the_pictures_it_had_reached
    stuck = RubyGBA.playthrough "wait for what never comes" do
      wait frames: 10
      moment :settled
      wait_until("the box has flown off", within: 3) { |game| game.var(:x) > 1000 }
      moment :never
    end

    Dir.mktmpdir("pictures") do |folder|
      assert_raises(RubyGBA::Playthroughs::GaveUp) { stuck.play(walker, pictures_in: folder) }
      assert_equal %w[settled.png], Dir.children(folder)
    end
  end

  # A folder that cannot be one is refused before anything is played. No cartridge is handed
  # over here, which is the proof of "before".
  def test_a_folder_for_pictures_that_is_a_file_is_refused
    Dir.mktmpdir("pictures") do |somewhere|
      a_file = File.join(somewhere, "notes.txt")
      File.write(a_file, "not a folder")
      err = assert_raises(ArgumentError) { walk_right.play(nil, pictures_in: a_file) }

      assert_match(/pictures_in/, err.message)
      assert_match(/notes\.txt/, err.message)
      assert_match(/a file/, err.message)
    end
  end

  def test_a_folder_for_pictures_that_is_not_a_path_is_refused
    [true, 3, :pictures, ""].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.play(nil, pictures_in: wrong) }

      assert_match(/pictures_in/, err.message)
      assert_match(/path of a folder/, err.message)
    end
  end

  # A folder that cannot be made — here, one inside something that is a file — is found
  # before anything is played, and not at the first moment.
  def test_a_folder_for_pictures_that_cannot_be_made_is_refused
    Dir.mktmpdir("pictures") do |somewhere|
      a_file = File.join(somewhere, "notes.txt")
      File.write(a_file, "not a folder")
      err = assert_raises(ArgumentError) { walk_right.play(nil, pictures_in: File.join(a_file, "pictures")) }

      assert_match(/pictures_in/, err.message)
      assert_match(/could not be made/, err.message)
    end
  end

  # TWO MOMENTS WHOSE NAMES DIFFER ONLY IN THEIR CAPITALS are two moments and, on a disk that
  # does not tell capitals from small letters, one file: the second picture would be written
  # over the first. So they are refused where pictures are asked for, and nowhere else.
  def test_two_moments_that_would_be_one_file_are_refused_where_pictures_are_written
    doors = RubyGBA.playthrough "two doors" do
      wait frames: 10
      moment :Door
      wait frames: 2
      moment :door
    end

    Dir.mktmpdir("pictures") do |folder|
      err = assert_raises(ArgumentError) { doors.play(nil, pictures_in: folder) }

      assert_match(/:Door/, err.message)
      assert_match(/:door/, err.message)
      assert_match(/same file/, err.message)
    end
    assert_equal %i[Door door], doors.play(walker).pictures.keys, "with no files asked for, they are two moments"
  end

  # A tape hands back the same pictures as the script it came from.
  def test_a_tape_hands_back_the_pictures_its_script_does
    cartridge = walker
    played = walk_right.play(cartridge)

    assert played.tape.play(cartridge).pictures == played.pictures
  end
end
