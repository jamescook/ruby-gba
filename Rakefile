# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

# gemba-core's built extension and the sources it comes from. The emulator-backed
# tests run on gemba-core (the headless libmgba probe), which is required, not
# optional — so a failed build stops the suite loudly rather than letting it pass
# with its coverage gutted.
#
# The built binary is a cached artifact: as a Rake file task it's rebuilt only
# when it's missing or a source is newer, so a plain `rake test` doesn't re-run
# extconf + make every time (that compile takes longer than the suite itself).
# It's gitignored, so it persists between runs locally and builds once on a fresh
# checkout.
GEMBA_CORE_EXT = "gemba-core/ext/gemba_core_ext"
GEMBA_CORE_BINARY = "#{GEMBA_CORE_EXT}/gemba_core_ext.#{RbConfig::CONFIG['DLEXT']}"
GEMBA_CORE_SOURCES = FileList["#{GEMBA_CORE_EXT}/*.{c,h}", "#{GEMBA_CORE_EXT}/extconf.rb"]

file GEMBA_CORE_BINARY => GEMBA_CORE_SOURCES do
  Dir.chdir("gemba-core") { sh "rake", "compile" }
end

desc "Build gemba-core's C extension if its sources changed (required for the tests)"
task compile_gemba_core: GEMBA_CORE_BINARY

Rake::TestTask.new(test: :compile_gemba_core) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

namespace :test do
  # gemba-core has its OWN test suite (its C extension + probe, tested in
  # isolation) — kept out of the main `test` glob above. Delegate to its
  # Rakefile, which compiles the extension first.
  desc "Compile and test gemba-core itself (the headless libmgba verification core)"
  task :mgba do
    Dir.chdir("gemba-core") { sh "rake", "test" }
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

task default: :test
