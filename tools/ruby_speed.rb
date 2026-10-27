#!/usr/bin/env ruby
# frozen_string_literal: true

# HOW FAST EACH GAME PLAYS AS RUBY, with each of Ruby's compilers and with none, so the numbers
# can be set side by side and compared across Ruby versions.
#
#   ruby tools/ruby_speed.rb                       every example
#   ruby tools/ruby_speed.rb ../ruby-wolf3d/wolf3d.rb
#   rake speed:ruby ONLY=pong,breakout PICTURES=600 JITS=none,yjit
#   rake speed:ruby GAMES=../ruby-wolf3d/wolf3d.rb SET=screen=floor,start=1
#
# Each game is played by `vblank run --uncapped`, which plays it as fast as this computer can and
# says how many pictures a second that was, in a program of its own for each compiler: a Ruby
# cannot turn a compiler off once it is on, and the two compilers cannot both be on. The window
# and the speaker are SDL's dummy ones, which show and play nothing, so nothing opens. The game
# is played as the first console it names, with no buttons held; SET hands it settings, as
# `vblank run --set` does, so a game that starts where a setting says can be measured there.
#
# The compilers turn the Ruby that runs most often into machine code as the game plays. YJIT is
# the one vblank run turns on; ZJIT is the newer one, which a Ruby has only when it was built
# with it (`--enable-zjit`, and the Rust compiler at build time). A Ruby without it shows its
# column as "no ZJIT".
#
# The same game can measure faster in one place than another on the same computer: a Mac puts a
# busy program on its slower cores or its faster ones by what else is going on, and a program
# started from a terminal a person is using tends to get the faster ones. Compare numbers measured
# the same way.
require "open3"
require "rbconfig"

module RubySpeed
  ROOT = File.expand_path("..", __dir__)
  VBLANK = File.join(ROOT, "bin", "vblank")

  # One way of playing: the column's name, what Ruby is started with, and what vblank run is told.
  Jit = Data.define(:label, :ruby_flags, :run_flags)
  JITS = {
    "none" => Jit.new(label: "no JIT", ruby_flags: [], run_flags: ["--no-yjit"]),
    "yjit" => Jit.new(label: "YJIT", ruby_flags: [], run_flags: []),
    "zjit" => Jit.new(label: "ZJIT", ruby_flags: ["--zjit"], run_flags: ["--no-yjit"])
  }.freeze

  # SDL's window and speaker that show and play nothing, and no YJIT turned on from outside (a
  # test run turns it on for every program it starts), so each column is played as it says.
  ENVIRONMENT = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBY_YJIT_ENABLE" => nil }.freeze

  # +games+ are game files, +jits+ some of JITS' keys, +settings+ "NAME=VALUE" words for each game.
  # Prints a table, a row a game.
  def self.measure(games, jits:, pictures:, settings: [])
    puts "Ruby #{RUBY_VERSION}, #{pictures} pictures, as fast as this computer can play them (pictures a second)"
    puts format_row("game", jits.map { |jit| JITS.fetch(jit).label })
    games.each do |game|
      puts format_row(File.basename(game, ".rb"), jits.map { |jit| measured_rate(game, JITS.fetch(jit), pictures, settings) })
    end
  end

  def self.format_row(name, cells) = ([name.ljust(16)] + cells.map { |cell| cell.to_s.rjust(10) }).join

  # The game's speed played with +jit+, as vblank run says it, or a word for why there is none.
  def self.measured_rate(game, jit, pictures, settings)
    return "no ZJIT" if jit.label == "ZJIT" && !zjit_built?

    command = [RbConfig.ruby, *jit.ruby_flags, VBLANK, "run", game, "--uncapped", "--pictures", pictures.to_s,
               *jit.run_flags, *settings.flat_map { |setting| ["--set", setting] }]
    said, status = Open3.capture2e(ENVIRONMENT, *command)
    return "failed" unless status.success?
    return "not #{jit.label}" unless said.include?("with #{jit.label}.")
    return "halts" if said.include?("Showed 0 pictures") # a still picture: nothing to measure

    said[/, ([\d.]+) a second\./, 1] || "failed"
  end

  # A Ruby built without ZJIT says "no", and one older than ZJIT says nothing.
  def self.zjit_built? = !["no", nil].include?(RbConfig::CONFIG["ZJIT_SUPPORT"])

  def self.examples = Dir.glob(File.join(ROOT, "examples", "*.rb")).sort
end

if $PROGRAM_NAME == __FILE__
  named = ARGV + ENV.fetch("GAMES", "").split(",")
  games = named.empty? ? RubySpeed.examples : named.map { |path| File.expand_path(path) }
  only = ENV["ONLY"]&.split(",")
  games = games.select { |game| only.include?(File.basename(game, ".rb")) } if only
  RubySpeed.measure(games, jits: (ENV["JITS"] || "none,yjit,zjit").split(","),
                           pictures: Integer(ENV.fetch("PICTURES", "300")),
                           settings: ENV.fetch("SET", "").split(","))
end
