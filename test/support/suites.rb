# frozen_string_literal: true

# WHICH LOWERING A RUN OF THE SUITE TESTS, and which files it loads, in one place, so the
# Rakefile and the tests read the same answer.
#
# A run tests ONE lowering. `rake test` plays every game on the interpreter (Backends::Reference)
# and checks the console through the emulator where a test asks for it; `rake test:native` plays
# them as C (Backends::Native). Both load every test file, and a test class runs only on the
# lowerings it names with `runs_on` (test_helper.rb), which every class with tests has to say.
# Native trails the other two (see atop IR::Backends), so a file is opted in once the native
# lowering can play the games in it, and never before.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  NATIVE_DIR = "test/ruby_gba/ir/backends/native"

  # The setting a run's lowering is read from. `rake test:native` sets it to "native"; nothing
  # sets it to anything else, and left alone it is the interpreter.
  LOWERING_SETTING = "RUBY_GBA_LOWERING"
  LOWERINGS = %i[reference native].freeze

  # The lowering this run tests, read once when the suite loads.
  LOWERING = ENV.fetch(LOWERING_SETTING, "reference").to_sym
  unless LOWERINGS.include?(LOWERING)
    raise ArgumentError, "#{LOWERING_SETTING} is #{LOWERING}, and a run can test #{LOWERINGS.join(' or ')}"
  end

  # The test of the program a player runs, with its window. It builds with SDL, whose first build
  # fetches its source over the network, so it is loaded only when asked (SDL=1).
  DESKTOP_TEST = Ractor.make_shareable("#{NATIVE_DIR}/test_native_desktop.rb")

  module_function

  def native? = LOWERING == :native

  # Every test file, for either run; the desktop test too when +desktop+.
  def files(desktop: false)
    found = Dir.glob("test/**/test_*.rb").sort
    desktop ? found : found - [DESKTOP_TEST]
  end

  # --- every class says where it runs ---
  #
  # A class that said nothing used to be the interpreter's alone. That made silence mean two
  # things nobody could tell apart: "the native lowering cannot play these yet" and "nobody has
  # looked". So a class with tests has to say (`runs_on`, in test_helper.rb), and a run with one
  # that has not is stopped before a test is played, naming it.

  # The classes among +classes+ that have tests and never said which lowerings they run on. A
  # class with no tests — minitest's own, or one that only holds shared helpers — has nothing to
  # run anywhere, and is left alone. A class inherits what the class above it said, so a
  # subclass of one that has said need not say again.
  def classes_naming_no_lowering(classes)
    classes.select { |klass| tests?(klass) && lowerings_of(klass).nil? }
  end

  # What to say about them, or nil when every class has said.
  def unnamed_lowerings_message(classes)
    silent = classes_naming_no_lowering(classes)
    return nil if silent.empty?

    "These test classes do not say which lowerings their tests run on:\n" \
      "#{silent.map { |klass| "  #{klass.name}#{where_declared(klass)}\n" }.sort.join}" \
      "Each test class must say. Add `runs_on :reference` for tests that only the interpreter and " \
      "the cartridge play. Add `runs_on :reference, :native` when the game built as C can play them " \
      "too, and use `game_player` where the tests say `Reference.new`. " \
      ".claude/rules/testing.md has the rule."
  end

  # How many of +classes+ run where, of the ones with tests: on both lowerings, on the native
  # one alone, on the interpreter alone.
  def class_counts_by_lowerings(classes)
    counts = { both: 0, native_only: 0, interpreter_only: 0 }
    classes.each do |klass|
      named = tests?(klass) && lowerings_of(klass)
      counts[where_named(named)] += 1 if named
    end
    counts
  end

  def where_named(lowerings)
    return :interpreter_only unless lowerings.include?(:native)

    lowerings.include?(:reference) ? :both : :native_only
  end

  # What a class said to `runs_on`, or nil: for one that never said, and for one that is not a
  # Minitest::Test at all and so was never asked.
  def lowerings_of(klass) = klass.respond_to?(:lowerings) ? klass.lowerings : nil

  # A test is a method minitest runs: `test_`, or `bench_` in a benchmark class.
  def tests?(klass) = klass.public_instance_methods.any? { |name| name.start_with?("test_", "bench_") }

  # " (file:line)" for a class with a name Ruby can find, and nothing for one without.
  def where_declared(klass)
    file, line = Object.const_source_location(klass.name.to_s)
    file ? " (#{file.delete_prefix("#{Dir.pwd}/")}:#{line})" : ""
  rescue NameError
    ""
  end
end
