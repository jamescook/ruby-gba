# frozen_string_literal: true

require "test_helper"
require "net/http"
require "stringio"
require "tmpdir"

# `ruby-gba preview`: the game as a page served on this computer, built again from its file each
# time the page is asked for, so an edit shows on the next reload — and a build that stops says
# why in the page instead.
class TestJSPreview < Minitest::Test
  Preview = RubyGBA::IR::Backends::JS::Preview

  private def game_source(title, color)
    <<~RUBY
      RubyGBA.game #{title.inspect} do
        screen :bitmap
        game_loop { clear_screen #{color.inspect} }
      end
    RUBY
  end

  # Serves +file+ for the length of the block, which is handed a way to fetch the page.
  private def serving(file, settings: [])
    preview = Preview.new(file, settings: settings, port: 0, out: StringIO.new)
    server = Thread.new { preview.serve }
    yield -> { Net::HTTP.get_response(URI(preview.url)) }
  ensure
    preview&.stop
    server&.join(5)
  end

  def test_a_reload_plays_the_game_as_its_file_says_now
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, game_source("FIRST", :blue))
      serving(file) do |fetch|
        first = fetch.call
        assert_equal "200", first.code
        assert_match(/<title>FIRST<\/title>/, first.body.force_encoding(Encoding::UTF_8))

        File.write(file, game_source("SECOND", :red))
        assert_match(/<title>SECOND<\/title>/, fetch.call.body.force_encoding(Encoding::UTF_8))
      end
    end
  end

  # Every setting reaches the build, not only the last: the game below has no default for either,
  # so a build missing one stops.
  def test_every_setting_reaches_the_build
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, <<~RUBY)
        RubyGBA.game "SETTINGS" do
          screen :bitmap
          setting :first
          setting :second
          game_loop { clear_screen :black }
        end
      RUBY
      serving(file, settings: %w[first=1 second=2]) do |fetch|
        page = fetch.call.body.force_encoding(Encoding::UTF_8)

        refute_match(/did not build/, page)
        assert_match(/<title>SETTINGS<\/title>/, page)
      end
    end
  end

  def test_a_build_that_stops_says_why_in_the_page
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, "RubyGBA.game \"BROKEN\" do\n  screen :bitmap\n  game_loop { clear_screen :no_such_color }\nend\n")
      serving(file) do |fetch|
        page = fetch.call.body.force_encoding(Encoding::UTF_8)

        assert_match(/The game did not build/, page)
        assert_match(/no_such_color/, page)
      end
    end
  end
end
