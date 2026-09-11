# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"
require_relative "tools/parallel_test"

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
# WHAT THIS DOES NOT CATCH is a change of Ruby version: a compiled extension is tied to the
# Ruby it was built against, and switching Ruby makes no source newer, so the binary stays
# "up to date" and refuses to load. That is what `rake clean` in ruby-gba-emulator/ is for, and
# the error you get says so. A CONSUMER of this library never meets it — they take the emulator
# through bundler, which installs extensions per Ruby ABI.
EMULATOR_DIR = "ruby-gba-emulator"
EMULATOR_EXT = "#{EMULATOR_DIR}/ext/ruby_gba_emulator_ext"
EMULATOR_BINARY =
  "#{EMULATOR_DIR}/lib/ruby_gba_emulator/ruby_gba_emulator_ext.#{RbConfig::CONFIG['DLEXT']}"
EMULATOR_SOURCES = FileList["#{EMULATOR_EXT}/*.{c,h}", "#{EMULATOR_EXT}/extconf.rb"]

file EMULATOR_BINARY => EMULATOR_SOURCES do
  Dir.chdir(EMULATOR_DIR) { sh "rake", "compile" }
end

desc "Build the emulator's C extension if its sources changed (required for the tests)"
task compile_emulator: EMULATOR_BINARY

# SimpleCov merges every result it finds in coverage/.resultset.json that is younger
# than its merge timeout, and each parallel shard files its slice under a name of its
# own — so without this a second run within a few minutes reports the UNION of both
# runs, and a line that stopped being covered still reads as covered. Every slice this
# run produces is written after this point, so clearing here loses nothing and keeps
# the report about the run that produced it.
task :clear_coverage do
  rm_f "coverage/.resultset.json" if ENV["COVERAGE"] == "1"
end

Rake::TestTask.new(test: %i[compile_emulator clear_coverage]) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  # `test` on the load path is what lets every test file open with the one line
  # `require "test_helper"` and get the library, minitest, and the shared names.
  t.description = 'Run ONE file or test in one process (rake test TEST=test/test_foo.rb ' \
                  'TESTOPTS="--name=/pattern/") — for the whole suite use rake test:parallel'
end

# Each rake test:parallel shard is its own process and only records its own
# slice of coverage (see test/test_helper.rb); this stitches every slice back
# into the one merged report a serial `COVERAGE=1 rake test` would have
# produced directly. Required lazily so plain `rake test:parallel` never loads
# simplecov at all.
def collate_coverage
  require "simplecov"
  require_relative "test/support/coverage"
  SimpleCov.collate(Dir["coverage/.resultset.json"], &Coverage::FILTERS)
end

namespace :test do
  # The same files as `rake test`, split across processes. Kept separate rather
  # than made the default because serial output is what you want the moment
  # something fails — and because the compile above has to finish before any
  # worker starts, which the dependency here guarantees.
  desc "Run the suite across processes (rake test:parallel JOBS=8)"
  task parallel: %i[compile_emulator clear_coverage] do
    ParallelTest.run(FileList["test/**/test_*.rb"].to_a)
    collate_coverage if ENV["COVERAGE"] == "1"
  end

  # The emulator gem has its OWN test suite (its C extension + probe, tested in isolation) —
  # kept out of the main `test` glob above. Delegate to its Rakefile, which compiles first.
  desc "Compile and test the emulator itself (the headless libmgba verification core)"
  task :emulator do
    Dir.chdir(EMULATOR_DIR) { sh "rake", "test" }
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

task default: :test
