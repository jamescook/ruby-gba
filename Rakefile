# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

namespace :test do
  # gemba-core (gemba-core/) is a headless libmgba binding used for dev/test
  # verification. It's a self-contained, unpublished mini-gem with a C
  # extension and its OWN test suite — kept out of the main `test` glob above so
  # `rake test` stays pure-Ruby and never needs a compiler. Delegate to its
  # Rakefile, which compiles the extension first.
  desc "Compile and test gemba-core (the headless libmgba verification core)"
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
