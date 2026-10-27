# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "vblank/live"

# A game written out as one Ruby file (Ruby#build_script), played by a Ruby that cannot load the
# vblank gem, in SDL's dummy window, which shows nothing: everything it needs is in the file.
class TestRubyScript < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby

  # A Ruby with none of the settings that would let it find this library or its gems.
  ALONE = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBYOPT" => nil, "RUBYLIB" => nil,
            "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "RUBY_YJIT_ENABLE" => nil }.freeze

  private def play_alone(game, console, *arguments)
    skip "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    Dir.mktmpdir do |dir|
      path = Ruby.new.build_script(game, File.join(dir, "game-ruby.rb"), console: console, err: StringIO.new)
      Open3.capture2e(ALONE, RbConfig.ruby, path, *arguments, chdir: dir)
    end
  end

  private def color_game
    VBlank.game("COLORSCRIPT", consoles: %i[gbc], menu: false) do
      game_loop { clear_screen :green }
    end
  end

  # A game for the Color, with no menu, plays as the Color in a window the size of its screen.
  def test_a_color_game_with_no_menu_plays_alone
    played, status = play_alone(color_game, :gbc, "--pictures", "3")

    assert status.success?, played
    assert_match(/Playing COLORSCRIPT\. Press P to pause/, played, "a game with no menu says nothing of F1")
    assert_match(/Showed 3 pictures/, played)
  end

  # A number of pictures that could never be reached is refused in words, rather than played forever.
  def test_a_script_refuses_no_pictures
    played, status = play_alone(color_game, :gbc, "--pictures", "0")

    refute status.success?, played
    assert_match(/--pictures must be a whole number above 0/, played)
  end
end
