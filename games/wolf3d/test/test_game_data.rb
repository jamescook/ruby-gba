# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestGameData < Minitest::Test
  include Wolf3DTest

  Data = Wolf3D::GameData

  def test_it_finds_a_complete_set_and_says_which_release_it_is
    with_release("WL6") do |dir|
      data = with_env(dir) { Data.locate(home: dir) }

      assert_equal "WL6", data.set
      assert_includes data.label, "registered"
      assert_includes data.describe, "WOLF3D_DATA"
    end
  end

  # The files are upper-case on the original disks and often lower-case after a copy through
  # another system, so neither can be assumed.
  def test_it_finds_files_whatever_case_they_are_in
    with_release("WL1", downcase: true) do |dir|
      data = with_env(dir) { Data.locate(home: dir) }

      assert_equal "WL1", data.set
      assert_equal "raw vswap", File.binread(data.path("VSWAP"))
    end
  end

  # The operator's own copy has spaces in its path, and so do most GOG installs.
  def test_it_handles_a_directory_whose_name_has_spaces
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "GOG Games", "Wolfenstein 3D")
      write_release(dir, "WL6")

      assert_equal "WL6", with_env(dir) { Data.locate(home: dir) }.set
    end
  end

  # Spear of Destiny ships inside the Wolfenstein folder. Reading flat rather than searching
  # downward is what keeps that from being read as two releases in one place.
  def test_a_release_in_a_sub_directory_is_not_mixed_into_its_parent
    Dir.mktmpdir do |tmp|
      write_release(tmp, "WL6")
      write_release(File.join(tmp, "m1"), "SOD")

      assert_equal "WL6", with_env(tmp) { Data.locate(home: tmp) }.set
      assert_equal "SOD", with_env(File.join(tmp, "m1")) { Data.locate(home: tmp) }.set
    end
  end

  def test_the_environment_wins_over_the_config_file
    with_release("WL6") do |env_dir|
      with_release("WL1") do |config_dir|
        File.write(File.join(config_dir, Data::CONFIG_FILE), { "data" => config_dir }.to_yaml)

        assert_equal "WL6", with_env(env_dir) { Data.locate(home: config_dir) }.set
        assert_equal "WL1", with_env(nil) { Data.locate(home: config_dir) }.set
      end
    end
  end

  def test_a_config_file_path_is_read_relative_to_the_game
    with_release("WL1", into: "beside") do |dir|
      home = File.expand_path("..", dir)
      File.write(File.join(home, Data::CONFIG_FILE), { "data" => "beside" }.to_yaml)

      assert_equal "WL1", with_env(nil) { Data.locate(home: home) }.set
    end
  end

  def test_an_incomplete_set_is_not_a_release
    with_release("WL6") do |dir|
      File.delete(File.join(dir, "MAPHEAD.WL6"))

      error = assert_raises(Data::NotFound) { with_env(dir) { Data.locate(home: dir) } }
      assert_includes error.message, "MAPHEAD"
    end
  end

  def test_saying_nothing_at_all_explains_both_ways_to_say_it
    Dir.mktmpdir do |home|
      error = assert_raises(Data::NotFound) { with_env(nil) { Data.locate(home: home) } }

      assert_includes error.message, "WOLF3D_DATA"
      assert_includes error.message, Data::CONFIG_FILE
      assert_includes error.message, "shareware"
    end
  end

  # The message tells you to copy a file. It named one that did not exist.
  def test_the_example_config_it_tells_you_to_copy_is_really_there
    assert_path_exists File.join(Wolf3D.home, Data::EXAMPLE_FILE)
    assert_includes Data.unset_message(Wolf3D.home), Data::EXAMPLE_FILE
  end

  # A config that only makes sense if the example it is copied from parses and names the key
  # the loader reads.
  def test_the_example_config_parses_and_uses_the_key_the_loader_reads
    example = YAML.safe_load_file(File.join(Wolf3D.home, Data::EXAMPLE_FILE))

    assert_kind_of Hash, example
    refute_nil example["data"]
  end

  def test_a_path_that_is_not_there_says_so_and_names_where_it_came_from
    Dir.mktmpdir do |home|
      missing = File.join(home, "nowhere")

      error = assert_raises(Data::NotFound) { with_env(missing) { Data.locate(home: home) } }
      assert_includes error.message, missing
      assert_includes error.message, "WOLF3D_DATA"
    end
  end

  def test_two_releases_in_one_directory_asks_which
    Dir.mktmpdir do |dir|
      write_release(dir, "WL6")
      write_release(dir, "WL1")

      error = assert_raises(Data::NotFound) { with_env(dir) { Data.locate(home: dir) } }
      assert_includes error.message, "WL6"
      assert_includes error.message, "WL1"
    end
  end

  def test_find_gives_back_nothing_rather_than_raising
    Dir.mktmpdir do |home|
      assert_nil with_env(nil) { Data.find(home: home) }
    end
  end

  private

  def with_release(set, downcase: false, into: nil)
    Dir.mktmpdir do |tmp|
      dir = into ? File.join(tmp, into) : tmp
      write_release(dir, set, downcase: downcase)
      yield dir
    end
  end

  def write_release(dir, set, downcase: false)
    FileUtils.mkdir_p(dir)
    Data::STEMS.each do |stem|
      name = "#{stem}.#{set}"
      File.binwrite(File.join(dir, downcase ? name.downcase : name), "raw #{stem.downcase}")
    end
  end

  def with_env(value)
    was = ENV.fetch(Data::ENV_VAR, nil)
    value.nil? ? ENV.delete(Data::ENV_VAR) : ENV[Data::ENV_VAR] = value
    yield
  ensure
    was.nil? ? ENV.delete(Data::ENV_VAR) : ENV[Data::ENV_VAR] = was
  end
end
