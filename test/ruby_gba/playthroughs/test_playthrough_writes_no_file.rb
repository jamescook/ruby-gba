# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# A PLAYTHROUGH THAT WAS NOT ASKED FOR PICTURES WRITES NO FILE. What it would get wrong is
# writing them somewhere nobody named — a folder of its own beside whatever ran it — so the
# test plays one from inside an empty folder and looks at what is in it afterwards.
class TestPlaythroughWritesNoFile < Minitest::Test
  runs_on :reference

  include ComparisonGames

  # It moves the whole process into another folder while it plays, which every other test
  # running at that moment would see.
  runs_on_the_main_ractor!

  def test_not_asked_for_pictures_it_leaves_the_folder_it_ran_in_empty
    cartridge = walker
    Dir.mktmpdir("playthrough-ran-here") do |folder|
      played = Dir.chdir(folder) { walk_right.play(cartridge) }

      assert_equal 2, played.pictures.size, "it took the pictures"
      assert_empty Dir.children(folder), "and wrote none of them"
    end
  end

  # The same playing, asked, does write — into the folder it was given and nowhere else.
  def test_asked_for_pictures_it_writes_them_where_it_was_told_and_nowhere_else
    cartridge = walker
    Dir.mktmpdir("playthrough-ran-here") do |folder|
      Dir.mktmpdir("pictures") do |pictures|
        Dir.chdir(folder) { walk_right.play(cartridge, pictures_in: pictures) }

        assert_equal %w[standing.png walked.png], Dir.children(pictures).sort
        assert_empty Dir.children(folder)
      end
    end
  end
end
