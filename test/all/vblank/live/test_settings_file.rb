# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"

# Where a player's settings are kept, found as the desktop build finds them, so the two share them.
# The operating system's place for vblank is a folder of the test's own.
class TestSettingsFile < Minitest::Test
  SettingsFile = VBlank::Live::SettingsFile

  # Keys named only as "key N", which is enough for these.
  class NumberedKeys
    def name(_key) = nil
    def key(_name) = nil
  end

  def test_with_no_files_the_settings_start_as_they_do_and_changes_go_to_the_shared_file
    with_settings_folder do |place|
      file = SettingsFile.new(title: "DEMO", folder_of: folders_in(place))
      settings = fresh

      assert_empty file.load(settings)
      assert_equal File.join(place, "(all games)", "settings.txt"), file.path
    end
  end

  def test_the_shared_file_is_read_and_written_with_every_setting
    with_settings_folder do |place|
      write(place, "(all games)", "volume = 30\n")
      file = SettingsFile.new(title: "DEMO", folder_of: folders_in(place))
      settings = fresh
      file.load(settings)
      settings.window = settings.window.with(scale: 5)

      assert_nil file.write(settings)
      text = File.read(File.join(place, "(all games)", "settings.txt"))
      assert_includes text, "volume = 30\n"
      assert_includes text, "scale = 5\n"
      assert_includes text, "key.a = key 27\n"
      refute settings.unwritten?
    end
  end

  # A game's own file is read over the shared one, and keeps only what it says and what changed.
  def test_a_games_own_file_is_read_over_the_shared_one_and_keeps_only_its_own
    with_settings_folder do |place|
      write(place, "(all games)", "volume = 30\nscale = 4\n")
      write(place, "MY GAME_", "scale = 2\n")
      file = SettingsFile.new(title: "MY GAME!", folder_of: folders_in(place))
      settings = fresh
      file.load(settings)

      assert_equal [30, 2], [settings.window.volume, settings.window.scale]
      settings.window = settings.window.with(muted: true)
      file.write(settings)
      text = File.read(File.join(place, "MY GAME_", "settings.txt"))
      assert_includes text, "scale = 2\n"
      assert_includes text, "mute = on\n"
      refute_match(/^volume/, text)
    end
  end

  # A file named for the play is the only one: the usual ones are not read.
  def test_a_file_asked_for_is_the_only_one
    with_settings_folder do |place|
      write(place, "(all games)", "volume = 30\n")
      asked = File.join(place, "mine.txt")
      File.write(asked, "volume = 70\n")
      file = SettingsFile.new(title: "DEMO", folder_of: folders_in(place), asked: asked)
      settings = fresh
      file.load(settings)

      assert_equal 70, settings.window.volume
      assert_equal asked, file.path
    end
  end

  def test_lines_that_cannot_be_used_are_said_under_the_files_name
    with_settings_folder do |place|
      write(place, "(all games)", "volume = loud\n")
      said = SettingsFile.new(title: "DEMO", folder_of: folders_in(place)).load(fresh)

      assert_equal File.join(place, "(all games)", "settings.txt:"), said.first
      assert_match(/\ALine 1: volume is a whole number/, said.last)
    end
  end

  def test_a_file_that_cannot_be_written_is_said_and_kept_to_write_again
    with_settings_folder do |place|
      file = SettingsFile.new(title: "DEMO", folder_of: folders_in(place), asked: File.join(place, "nowhere", "s.txt"))
      settings = fresh
      file.load(settings)
      settings.window = settings.window.with(volume: 10)

      assert_match(/DEMO cannot write its settings to .*nowhere/, file.write(settings))
      assert settings.unwritten?
    end
  end

  def test_a_games_folder_is_named_from_its_title_as_the_desktop_build_names_it
    assert_equal "Super Game_ 2", SettingsFile.folder_named("Super Game! 2")
    assert_equal "game", SettingsFile.folder_named("")
  end

  private

  def fresh = VBlank::Live::Settings.new(key_names: NumberedKeys.new)

  def with_settings_folder(&) = Dir.mktmpdir("vblank-settings", &)

  def folders_in(place)
    lambda do |name|
      folder = File.join(place, name)
      FileUtils.mkdir_p(folder)
      folder
    end
  end

  def write(place, folder, text)
    FileUtils.mkdir_p(File.join(place, folder))
    File.write(File.join(place, folder, "settings.txt"), text)
  end
end
