# frozen_string_literal: true

# WHICH TEST FILES EACH SUITE RUNS, in one place, so the Rakefile and the tests that check the
# split read the same answer. Why there are two suites is said once, atop IR::Backends: the
# native backend trails the other two, and its tests need zig.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  NATIVE_DIR = "test/ruby_gba/ir/backends/native"

  # Set by `rake test:native` for the run, and by nothing else. A native test that finds it
  # missing was started by some other suite.
  NATIVE_RUN = "RUBY_GBA_NATIVE_SUITE"

  module_function

  # Everything `rake test` runs: every test file except the trailing backends'.
  def main
    Dir.glob("test/**/test_*.rb").sort.reject { |path| path.start_with?("#{NATIVE_DIR}/") }
  end

  # The tests of the program a player runs, with its window. They build with SDL, whose first
  # build fetches its source over the network, so they run only when asked (SDL=1).
  DESKTOP_DIR = "#{NATIVE_DIR}/desktop"

  # Everything `rake test:native` runs, and nothing else; the desktop tests too when +desktop+.
  def native(desktop: false)
    files = Dir.glob("#{NATIVE_DIR}/**/test_*.rb").sort
    desktop ? files : files.reject { |path| path.start_with?("#{DESKTOP_DIR}/") }
  end
end
