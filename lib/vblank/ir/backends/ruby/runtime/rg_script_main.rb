# frozen_string_literal: true

# THE LAST PART OF A GAME WRITTEN OUT AS ONE RUBY FILE (Ruby#script): what runs when somebody
# plays it with `ruby game-ruby.rb`. Everything above it in that file — the game as Ruby in
# VBlankScript::SOURCE, its title and whether it has a menu, and the window, the menu and the
# session it plays in — was copied in when it was built, so it needs no vblank gem. It is never
# loaded by the library itself. What vblank run says as it plays is said here in the same words.
require "optparse"

module VBlankScript
  # Plays the game in a window until the player stops it, and says how fast it went, as vblank run
  # does. The options are a few of vblank run's.
  def self.main(arguments)
    options = { scale: 3 }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby #{File.basename($PROGRAM_NAME)} [options]"
      parser.on("--scale N", Integer, "The window is N times the size of the screen. Default: 3.")
      parser.on("--pictures N", Integer, "Stop after the window has shown N pictures.")
      parser.on("--uncapped", "Do not wait for the end of each frame, to measure the speed.")
    end.parse!(arguments, into: options)
    %i[scale pictures].each do |name|
      raise OptionParser::InvalidArgument, "--#{name} must be a whole number above 0" if options[name]&.<(1)
    end
    # YJIT turns the Ruby that runs most often into machine code as the game plays, which plays it
    # several times faster. A Ruby built without it plays the game slower, and one started with
    # ZJIT, the other of Ruby's compilers, keeps it.
    RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled? && !(defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?)
    play(options)
  rescue OptionParser::ParseError, VBlank::Live::SDL::Missing, VBlank::Live::SDL::Failed, VBlank::IR::ProgramError => e
    warn e.message
    exit 1
  end

  def self.play(options)
    game = VBlank::IR::Backends::Ruby::LiveGame.new(SOURCE)
    window = VBlank::Live::SDL.new(title: TITLE, scale: options[:scale], width: game.width, height: game.height,
                                   menu: MENU)
    puts "Playing #{TITLE}. #{'Press F1 or ` for the menu. ' if MENU}Press P to pause. Hold Tab to play fast. " \
         "Press Escape to stop."
    rate = VBlank::Live::Session.new(game: game, uncapped: options[:uncapped], stop_after_passes: options[:pictures])
                                .play(window)
    if rate.passes.positive?
      puts format("Showed %<pictures>d pictures in %<seconds>.1f seconds, %<per_second>.1f a second. " \
                  "The console shows %<console>.1f a second.",
                  pictures: rate.passes, seconds: rate.seconds, per_second: rate.passes_per_second,
                  console: 1 / game.frame_seconds)
    end
    puts "#{TITLE} stopped itself. Its last picture stayed in the window." if rate.stopped_itself?
  ensure
    window&.close
  end
end

VBlankScript.main(ARGV) if $PROGRAM_NAME == __FILE__
