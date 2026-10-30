# frozen_string_literal: true

require "test_helper"
require "open3"
require "vblank/live"

# tools/ruby_speed.rb plays each game as Ruby as fast as the computer can, once for each of Ruby's
# compilers and once with none, and prints a row a game. These play one small example for a few
# pictures; a computer without SDL3 skips them.
class TestRubySpeedTool < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor. See test_helper.
  runs_on_the_main_ractor!

  ROOT = VBlank.root.to_s

  def test_it_prints_each_games_speed_with_each_compiler
    skip "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    printed, status = Open3.capture2e({ "JITS" => "none,yjit,zjit", "PICTURES" => "3" }, Gem.ruby,
                                      File.join(ROOT, "tools", "ruby_speed.rb"), "examples/pong.rb", chdir: ROOT)

    assert_predicate status, :success?, printed
    table = printed.lines.drop_while { |line| !line.start_with?("game ") }
    header, row = table.first(2).map { |line| columns(line) }
    assert_equal ["game", "no JIT", "YJIT", "ZJIT"], header
    assert_equal "pong", row[0]
    assert_match(/\A[\d.]+\z/, row[1], "with no JIT")
    assert_match(/\A[\d.]+\z/, row[2], "with YJIT")
    assert_match(/\A([\d.]+|no ZJIT)\z/, row[3], "with ZJIT, where this Ruby has it")
  end

  # The table's columns: the name in 16 letters, then 10 for each speed.
  private def columns(line) = [line[0, 16].strip, *line.chomp[16..].scan(/.{10}/).map(&:strip)]
end
