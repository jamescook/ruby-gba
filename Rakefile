# frozen_string_literal: true

# So a bare `rake` sees what the Gemfile declares, the way `bundle exec rake` does. Without
# it the test runner — declared there, not in the gemspec — is not on the load path.
require "bundler/setup"

require "rake/testtask"
require "rbconfig"
require_relative "ruby-gba-emulator/lib/ruby_gba_emulator/built_for"

# The emulator's built extension and the sources it comes from. The emulator-backed tests run
# on ruby-gba-emulator (the headless libmgba probe, a gem of its own in this repository), which
# is required, not optional — so a failed build stops the suite loudly rather than letting it
# pass with its coverage gutted.
#
# The built binary is a cached artifact: as a Rake file task it's rebuilt only when it's
# missing or a source is newer, so a plain `rake test` doesn't re-run extconf + make every time
# (that compile takes longer than the suite itself). It's gitignored, so it persists between
# runs locally and builds once on a fresh checkout.
#
# A CHANGE OF RUBY COUNTS AS MISSING, and that is what makes caching this safe. An extension
# is tied to the Ruby that built it, and a change of Ruby makes no source newer, so one shared
# path would stay "up to date" while holding a binary that cannot be loaded. The build goes
# under a directory naming its Ruby instead, so a Ruby that has not built it finds nothing there
# and compiles its own. A CONSUMER of this library never meets it — they take the emulator
# through bundler, which installs extensions per Ruby ABI.
EMULATOR_DIR = "ruby-gba-emulator"
EMULATOR_EXT = "#{EMULATOR_DIR}/ext/ruby_gba_emulator_ext"
EMULATOR_BINARY =
  "#{EMULATOR_DIR}/lib/#{RubyGBAEmulator::BUILT_FOR}/ruby_gba_emulator/" \
  "ruby_gba_emulator_ext.#{RbConfig::CONFIG['DLEXT']}"
EMULATOR_SOURCES = FileList["#{EMULATOR_EXT}/*.{c,h}", "#{EMULATOR_EXT}/extconf.rb"]

file EMULATOR_BINARY => EMULATOR_SOURCES do
  Dir.chdir(EMULATOR_DIR) { sh "rake", "compile" }
end

desc "Build the emulator's C extension if its sources changed (required for the tests)"
task compile_emulator: EMULATOR_BINARY

# SimpleCov merges every result it finds in coverage/.resultset.json that is younger
# than its merge timeout, and each run files its slice under a name of its
# own — so without this a second run within a few minutes reports the UNION of both
# runs, and a line that stopped being covered still reads as covered. Every slice this
# run produces is written after this point, so clearing here loses nothing and keeps
# the report about the run that produced it.
task :clear_coverage do
  rm_f "coverage/.resultset.json" if ENV["COVERAGE"] == "1"
end

# EVERY TEST IN A RACTOR OF ITS OWN, however the suite is started. The flag goes into TESTOPTS
# itself rather than into the task's options, because rake reads TESTOPTS INSTEAD of those when
# it is set: naming one test with `TESTOPTS="--name=/x/"` used to drop the flag and run that
# test on plain threads, where something the suite refuses passes. It is matched as a whole
# word, so a pattern that happens to say "ractor" is not taken for it, and `--no-ractor` is
# left to mean what it says.
testopts = ENV.fetch("TESTOPTS", "")
GIVEN_TESTOPTS = testopts # as the caller wrote them, for a suite that is not run on Ractors
unless testopts.split.intersect?(%w[--ractor --no-ractor])
  ENV["TESTOPTS"] = "--ractor #{testopts}".strip
end

Rake::TestTask.new(test: %i[compile_emulator clear_coverage]) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  # `test` on the load path is what lets every test file open with the one line
  # `require "test_helper"` and get the library, minitest, and the shared names.
  t.description = 'Run the suite (one file with TEST=test/test_foo.rb, one test with ' \
                  'TESTOPTS="--name=/pattern/")'
end

namespace :test do
  # The emulator gem has its OWN test suite (its C extension + probe, tested in isolation) —
  # kept out of the main `test` glob above. Delegate to its Rakefile, which compiles first.
  #
  # It is handed the test options as the caller wrote them, not with the `--ractor` added
  # above: that flag belongs to this suite's runner, and the gem's is plain minitest, which
  # refused it and ran nothing — so this task failed before a single test of the emulator ran.
  desc "Compile and test the emulator itself (the headless libmgba verification core)"
  task :emulator do
    Dir.chdir(EMULATOR_DIR) { sh({ "TESTOPTS" => GIVEN_TESTOPTS }, "rake", "test") }
  end
end

desc "Did a compiler change alter what it emits? Build every example twice (rake emitted REF=HEAD~3 ONLY=pong)"
task :emitted do
  require_relative "tools/emitted"
  Emitted.run(ref: ENV["REF"] || "HEAD", only: ENV["ONLY"])
end

namespace :emitted do
  desc "Record what every example emits, as the baseline nothing may grow past"
  task :record do
    require_relative "tools/emitted_baseline"
    abort "Nothing recorded." unless Emitted::Baseline.record
  end

  desc "Fail if any example emits more than the recorded baseline"
  task :check do
    require_relative "tools/emitted_baseline"
    abort unless Emitted::Baseline.check
  end
end

desc "Render examples/EXAMPLE.rb to a watchable HTML page (rake preview EXAMPLE=parallax KEYS=right FRAMES=64)"
task :preview do
  example = ENV["EXAMPLE"] || abort("set EXAMPLE, e.g. rake preview EXAMPLE=parallax KEYS=right")
  cmd = ["ruby", "tools/preview.rb", example]
  cmd += ["--keys", ENV["KEYS"]] if ENV["KEYS"]
  cmd += ["--frames", ENV["FRAMES"]] if ENV["FRAMES"]
  sh(*cmd)
end

# The codebase map in .ua/ is committed, so browsing it costs nothing: the viewer is
# a self-contained local page — no analysis run, no LLM, no API key, no account. It's
# fetched straight from the upstream project's latest release rather than vendored
# here, so there's nothing to install and nothing to keep in sync. It prints a URL
# with a token on it; that token is required, so open the whole line it gives you.
UA_VIEWER = "https://github.com/Egonex-AI/Understand-Anything/releases/latest/download/" \
            "understand-anything-viewer.tgz"

desc "Browse the codebase map in .ua/ in a local dashboard (needs Node 18 or newer)"
task :ua do
  unless File.exist?(".ua/knowledge-graph.json")
    abort "There is no codebase map at .ua/knowledge-graph.json. To make one, run /understand in Claude Code."
  end
  sh "npx", "--yes", UA_VIEWER, "."
end

desc "Check nothing a build PRINTS calls the quick memory anything else (comments are exempt)"
task :plain_words do
  require_relative "tools/plain_words_scan"
  abort unless PlainWordsScan.run
end

desc "Lint with RuboCop (performance cops only)"
task :rubocop do
  sh "rubocop"
end

task default: :test
