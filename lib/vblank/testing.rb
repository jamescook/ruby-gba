# frozen_string_literal: true

# A GAME'S OWN TESTS, PLAYED ON EITHER LOWERING. The one require a game's test suite needs:
#
#   require "vblank/testing"
#
#   class WalkerTest < Minitest::Test
#     include VBlank::Testing
#
#     def test_holding_right_walks
#       assert_equal 6, game_player.hold(:right).run(game.program, frames: 6)[:x]
#     end
#   end
#
# `game_player` is the interpreter on the GBA lowering's run, the game built as C, checked
# against the interpreter on every frame, on the native lowering's, and the game built as
# JavaScript, checked the same way, on the JavaScript lowering's — the same calls every way, so a
# test is written once and plays on all three. Which run it is comes from one setting
# (Lowering::SETTING), which the rake tasks set (vblank/testing/rake_tasks); a plain run is the
# GBA lowering's.
#
# A test that asks whether the CARTRIDGE draws what the interpreter draws includes Pictures as
# well (`include VBlank::Testing::Pictures`, for `assert_backends_agree`). That one plays the
# cartridge in the emulator, so it needs the ruby-gba-emulator gem in the game's test group.
#
# It is not part of `require "vblank"`, because it loads minitest, which a game needs only for
# its tests: a game's Gemfile names minitest in its test group. The native lowering's run needs
# zig as well, as every native build does, and the JavaScript lowering's needs node.
require "minitest/autorun"
require_relative "../vblank"
require_relative "testing/lowering"
require_relative "testing/checked_player"
require_relative "testing/pictures"

module VBlank
  module Testing
    # The lowering this run tests, read once when the suite loads, and its record (Lowering::Run).
    LOWERING = Lowering.from(ENV)
    RUN = Lowering.run_named(LOWERING)

    def self.lowering = LOWERING
    def self.native? = LOWERING == :native
    def self.javascript? = LOWERING == :js
    def self.gbc? = LOWERING == :gbc

    # The console this run plays a game built for (Lowering::Run#console): the Game Boy Color on
    # its run, the Advance on the native, JavaScript and Ruby ones unless CONSOLE names another
    # (Lowering.console_from). A game for both builds its tree for the run's
    # (`game.program(console: game_console)`), so its tests play on the Color too.
    CONSOLE = Lowering.console_from(ENV, RUN)

    def self.console = CONSOLE
    def game_console = Testing.console

    # HOW MANY PASSES BEHIND THE GAME'S NUMBERS what the framework draws for it is — its sprites,
    # its tiled text, its scroll — read at a frame boundary on this run's console. One on the
    # Advance, which places them in the gap after the boundary from the pass before; none on the
    # Color, which places them before it from the pass just ended
    # (Console::Description#sprites_placed_before_wait). What the game draws itself is never behind.
    def framework_drawing_lag = Console.described(game_console).sprites_placed_before_wait ? 0 : 1

    # THE EMULATOR, IF THE GAME HAS IT, LOADED NOW rather than by the first test that wants it.
    # A suite may play its tests in Ractors, and loading it writes globals only the main Ractor
    # may touch (see Diagnostics::Emulator.load!). A game without it in its test group loses
    # only the tests that play the cartridge, which say so when they run.
    Diagnostics::Emulator.available?

    # STANDARD OUTPUT UNBUFFERED, so a test in a Ractor can start a program. In Ruby 4.0, before
    # it starts one it flushes the process's standard output, and if words are waiting it takes the
    # lock of an object the main Ractor owns. When the main Ractor is writing the run's progress
    # at that moment, the test waits on a lock no thread of its own can release, and Ruby stops
    # it as a deadlock (or, now and then, the whole process crashes). With nothing ever left
    # waiting in the buffer, the flush has nothing to do and takes no lock. Building a game whose
    # art is read from a file starts ImageMagick, so this reaches far more tests than it sounds.
    $stdout.sync = true

    # Whether this run plays the game built for another machine (as C, as JavaScript, or as a Game
    # Boy Color cartridge) and checks it against the interpreter, rather than playing the
    # interpreter alone. Such a run has no Advance cartridge to check.
    def self.checked? = RUN.checked?

    # What plays a game in this run: the interpreter on the GBA lowering's run; on the native
    # lowering's the game built as C, driven through the same calls and checked against the
    # interpreter frame by frame (CheckedPlayer); and on the JavaScript lowering's the game built
    # as JavaScript, checked the same way (JSCheckedPlayer). +save+ is the save memory the game
    # starts with, as the interpreter takes it.
    def game_player(save: nil)
      player = Testing.player_class
      save ? player.new(save: save) : player.new
    end

    # +program+ as game_player plays it on this run: the same program, except on the Game Boy
    # Color's run, where a program that names no console is played as a Color program. A test
    # that asks a build check about the program it played asks it of this.
    def program_played(program)
      player = Testing.player_class
      player.respond_to?(:program_played) ? player.program_played(program) : program
    end

    # The class game_player makes one of, for this run (Lowering::Run#player).
    def self.player_class = RUN.player_class

    # A test the native lowering cannot play yet skips itself on a native run, saying +why+
    # (skip_on_native) — and a checked run ends by counting its skips by reason, so these cannot
    # pile up unseen. On the GBA lowering's run it does nothing. There is one for every checked
    # run in Lowering::RUNS, by its name: skip_on_native, skip_on_js, skip_on_ruby, skip_on_gbc,
    # skip_on_snes. Each is written out as a plain method, not made from a block, so a test in a
    # Ractor can call it.
    Lowering::RUNS.select(&:checked?).each do |run|
      module_eval("def skip_on_#{run.name}(why) = skip_on_lowering(:#{run.name}, why)", __FILE__, __LINE__)
    end

    # The same, for the run of the lowering named +lowering+.
    # A name no lowering has is refused on every run, so a misspelt one cannot quietly never skip.
    def skip_on_lowering(lowering, why)
      run = Lowering.run_named(lowering)
      raise MissingFeature, "#{run.title} cannot play this yet: #{why}" if Testing.lowering == lowering
    end

    # A test of something +console+'s HARDWARE cannot do skips on every run playing games as that
    # console, saying +why+: the console's own cartridge run and a runtime's run built as it alike
    # (`skip_on_console :gbc, "it cannot loop a recording"`). skip_on_<lowering> is for what one
    # lowering does not make, which a runtime built as the same console can still play.
    def skip_on_console(console, why)
      named = Console.named(console)
      raise MissingFeature, "#{Console.for(named).title} cannot do this: #{why}" if Testing.console == named
    end

    # THE ONE KIND OF SKIP A RUN TAKES: its lowering lacks the feature the test plays — its build
    # does not make it yet, or its hardware cannot. A checked player raises it for what its
    # lowering does not make or answer, and skip_on_<run> for what a test says it cannot play.
    # Any other skip is a test in the wrong place, and fails the run (SkipsByReason).
    #
    # It is a plain Minitest::Skip with a mark on it, not a kind of its own: minitest counts a
    # run's skips by the exact class of each, so one of its own would go uncounted. The mark is an
    # instance variable, which Marshal carries from the process that played the test to the one
    # that reports it (Testing::Processes). `raise MissingFeature, "why"` raises one.
    module MissingFeature
      def self.exception(message) = Minitest::Skip.new(message).tap { |skip| skip.instance_variable_set(:@missing_feature, true) }

      # Whether +failure+ is one.
      def self.===(failure) = failure.is_a?(Minitest::Skip) && failure.instance_variable_get(:@missing_feature) == true
    end
  end
end

require_relative "testing/skips_by_reason"

# On a CI machine, whose log shows a line only once it ends, a line every hundred tests.
require_relative "testing/progress_lines"
if ENV["CI"]
  module Minitest
    def self.plugin_progress_lines_init(options) = reporter << VBlank::Testing::ProgressLines.for_run(options)
  end
  Minitest.extensions << "progress_lines"
end
