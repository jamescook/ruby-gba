# frozen_string_literal: true

# WHICH LOWERING A RUN OF THE SUITE TESTS, and which files it loads, in one place, so the
# Rakefile and the tests read the same answer.
#
# A run tests ONE lowering. `rake test` plays every game on the interpreter (Backends::Reference)
# and checks the console through the emulator where a test asks for it; `rake test:native` plays
# them as C (Backends::Native). Both load every test file, and a test class runs only on the
# lowerings it names with `runs_on` (test_helper.rb) — the interpreter alone when it names none.
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

  # Every test file, for either run; the desktop test too when +desktop+.
  def files(desktop: false)
    found = Dir.glob("test/**/test_*.rb").sort
    desktop ? found : found - [DESKTOP_TEST]
  end
end
