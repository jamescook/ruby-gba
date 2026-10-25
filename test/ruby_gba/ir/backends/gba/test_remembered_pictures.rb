# frozen_string_literal: true

require "test_helper"

# WHAT ONE BUILD WORKED OUT ABOUT A PICTURE, READ BACK BY THE NEXT, never changes a cartridge.
# A build keeps where each picture draws, its turned forms, its colours and its tiles for the
# next build on the same core (see IR::Remembered), so a game here is built after another game
# on its core and on a core of its own that has built nothing, and the two must be the same
# bytes — and the second build must really have read the first one's answers.
class TestRememberedPictures < Minitest::Test
  # A shape that is not the same turned any way, three tiles wide so it is cut into pieces.
  ART = <<~ART
    ##..........##........##
    #.#........#..#......#.#
    #..#..o...#....#....#..#
    #...#....#......#..#...#
    #....#..#........##....#
    #.....##..........#....#
    #......#.........#.....#
    ########################
  ART

  # The same size and colours, the blue pixel one place to the left.
  CHANGED_ART = ART.sub("..o.", ".o..")

  FIRST = proc do
    screen :tiled
    image(:hero, "." => :transparent, "#" => :red, "o" => :blue) { TestRememberedPictures::ART }
    sprite :hero, at: [40, 40]
    game_loop {}
  end

  # The first game's picture under another name, beside another sprite, somewhere else.
  SAME_PICTURE = proc do
    screen :tiled
    image(:walker, "." => :transparent, "#" => :red, "o" => :blue) { TestRememberedPictures::ART }
    image(:coin, "#" => :yellow) { Array.new(8) { "#" * 8 }.join("\n") }
    sprite :coin, at: [100, 60]
    sprite :walker, at: [10, 20]
    game_loop {}
  end

  # A picture with the first game's name and other pixels.
  SAME_NAME = proc do
    screen :tiled
    image(:hero, "." => :transparent, "#" => :red, "o" => :blue) { TestRememberedPictures::CHANGED_ART }
    sprite :hero, at: [40, 40]
    game_loop {}
  end

  # The first game's picture and nothing else, under another name and somewhere else.
  SAME_PICTURE_ALONE = proc do
    screen :tiled
    image(:walker, "." => :transparent, "#" => :red, "o" => :blue) { TestRememberedPictures::ART }
    sprite :walker, at: [10, 20]
    game_loop {}
  end

  def self.cartridge(source)
    builder = Builder.new
    builder.instance_eval(&source)
    builder.finalize_program
    GBA.new.lower(builder.program)
  end

  private def built_after_the_first(source)
    TestRememberedPictures.cartridge(FIRST)
    TestRememberedPictures.cartridge(source)
  end

  private def built_on_a_core_of_its_own(source)
    Ractor.new(source) { |game| TestRememberedPictures.cartridge(game) }.value
  end

  # Compared as a yes or no: a cartridge is thousands of bytes, and a failure that printed
  # both would say less than this does.
  private def assert_same_cartridge(source)
    assert built_on_a_core_of_its_own(source) == built_after_the_first(source),
           "the game built after another one is not the same bytes as built on a core of its own"
  end

  def test_a_game_holding_a_picture_built_before_comes_out_the_same
    assert_same_cartridge(SAME_PICTURE)
  end

  def test_a_picture_of_a_name_built_before_is_read_by_its_own_pixels
    assert_same_cartridge(SAME_NAME)
  end

  # The second build really reads the first one's answers: holding nothing but a picture the
  # first already worked out, it adds nothing of its own to what the core keeps.
  def test_a_build_of_a_picture_worked_out_before_does_none_of_the_work_again
    first, second = Ractor.new do
      remembered = RubyGBA::IR::Remembered
      TestRememberedPictures.cartridge(TestRememberedPictures::FIRST)
      after_first = remembered.size
      TestRememberedPictures.cartridge(TestRememberedPictures::SAME_PICTURE_ALONE)
      [after_first, remembered.size - after_first]
    end.value
    assert_operator first, :>, 0, "the first build kept what it worked out"
    assert_equal 0, second, "the second build worked nothing out again"
  end

  # Several cores building at the same moment each keep their own answers, and every one of
  # them builds what a core building alone does.
  def test_cores_building_at_once_each_build_the_same_cartridges
    alone = Ractor.new do
      [TestRememberedPictures.cartridge(TestRememberedPictures::FIRST),
       TestRememberedPictures.cartridge(TestRememberedPictures::SAME_PICTURE)]
    end.value
    together = Array.new(3) do
      Ractor.new do
        [TestRememberedPictures.cartridge(TestRememberedPictures::FIRST),
         TestRememberedPictures.cartridge(TestRememberedPictures::SAME_PICTURE)]
      end
    end.map(&:value)
    together.each_with_index do |built, core|
      assert built == alone, "core #{core} of three building at once built other bytes than a core alone"
    end
  end
end
