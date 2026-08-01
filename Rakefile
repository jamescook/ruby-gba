# frozen_string_literal: true

require "rake/testtask"

# Build gemba-core's C extension (the headless libmgba probe that the
# emulator-backed tests run on) before the suite. gemba-core is required to run
# the tests — the emulator path is not optional — so if it can't build, fail
# loudly and stop, rather than letting the suite pass with its coverage gutted.
desc "Build gemba-core's C extension (required for the emulator-backed tests)"
task :compile_gemba_core do
  Dir.chdir("gemba-core") { sh "rake", "compile" }
end

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
