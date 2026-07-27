# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
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
