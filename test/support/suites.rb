# frozen_string_literal: true

# WHICH TEST FILES EACH SUITE RUNS, in one place, so the Rakefile and the test that checks the
# split read the same answer.
#
# The backends are not all held to the same standard, and the suites are how that is kept. The
# console and the interpreter are first-class: `rake test` runs them, and a feature is not done
# until it works on both. The native backend trails: its tests run under `rake test:native` and
# never under `rake test`, so a feature that lands on the first two and not yet on native is a
# gap to fill rather than a broken build. Its tests also need zig to compile what they test,
# which nobody running `rake test` should need. (IR::Backends says the same split once, in the
# library.)
#
# Plain globbing rather than Rake's FileList, because the test that checks this runs in a
# Ractor and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  NATIVE_DIR = "test/ruby_gba/ir/backends/native"

  module_function

  # Everything `rake test` runs: every test file except the trailing backends'.
  def main
    Dir.glob("test/**/test_*.rb").sort.reject { |path| path.start_with?("#{NATIVE_DIR}/") }
  end

  # Everything `rake test:native` runs, and nothing else.
  def native
    Dir.glob("#{NATIVE_DIR}/**/test_*.rb").sort
  end
end
