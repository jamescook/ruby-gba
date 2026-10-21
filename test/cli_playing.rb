# frozen_string_literal: true

require "open3"
require "rbconfig"

# WHAT THE TESTS OF `ruby-gba play` AND `ruby-gba compare` SHARE: the command run the way a
# person runs it, in a process of its own, and the files it is pointed at — a game, and
# scripts that play it.
#
#   include CLIPlaying
module CLIPlaying
  # Which Ruby to launch, asked once here. Asking reads Ruby's own table of how it was
  # built, which is not something a worker may touch — and these tests run in a pool.
  RUBY = RbConfig.ruby.freeze
  BIN = RubyGBA.root.join("bin/ruby-gba").to_s.freeze

  # A white box on a blue ground, that walks while RIGHT is down and keeps the furthest it
  # has been in save memory. Two settings make a second game of it that differs in one
  # thing: how far it walks a frame, and the tick its ground turns red on.
  GAME = <<~RUBY
    require "ruby_gba"

    RubyGBA.game "WALKER", consoles: %i[gba] do
      screen :bitmap
      speed = setting :speed, 2
      red_at = setting :red_at, 100_000
      ticks = var :ticks, 0
      x = var :x, 20
      best = save_var :best, 0
      game_loop do
        ticks.add! 1
        held(:right).then { x.add! speed }
        (x > best).then { best.set! x }
        (ticks >= red_at).then { clear_screen :red }.else { clear_screen :blue }
        draw_rect_at x, 60, 8, 8, :white
      end
    end
  RUBY

  # One playthrough: stand, walk right for twenty frames, stand.
  WALK = <<~RUBY
    RubyGBA.playthrough "walk" do
      wait frames: 10
      moment :standing
      hold :right, frames: 20
      moment :walked
      wait frames: 30
    end
  RUBY

  # Three playthroughs in one file: one to stand, one to walk until the box is somewhere,
  # and one to let a few frames go by before either.
  SEVERAL = <<~RUBY
    RubyGBA.playthrough "stand" do
      wait frames: 12
      moment :stood
    end

    RubyGBA.playthrough "walk to sixty" do
      wait frames: 10
      moment :standing
      hold_until("the box is at sixty", :right) { |game| game.var(:x) >= 60 }
      moment :arrived
    end

    RubyGBA.playthrough "five frames" do
      wait frames: 5
    end
  RUBY

  # Run the command in +dir+, and hand back what it printed and how it ended.
  def cli(*args, dir:)
    Open3.capture2e(RUBY, BIN, *args, chdir: dir)
  end

  # A folder holding the game and the scripts, handed to the block.
  def with_game_and_scripts
    Dir.mktmpdir("cli") do |dir|
      File.write(File.join(dir, "walker.rb"), GAME)
      File.write(File.join(dir, "walk.rb"), WALK)
      File.write(File.join(dir, "several.rb"), SEVERAL)
      yield dir
    end
  end
end
