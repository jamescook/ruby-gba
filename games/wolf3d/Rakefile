# frozen_string_literal: true

require "rake/testtask"

# This game's own suite, run from this directory and nowhere else. The framework's rake does not
# know this game exists, and should not: a library that names the games built on it is coupled to
# them. It also could not run this usefully — most of what this will grow to check needs a copy of
# Wolfenstein 3D that cannot be redistributed, so it would fail on every machine but one.
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

# The same files split across processes, with the framework's own runner: it shards by
# each file's recorded time from the last run (kept beside this suite, in this directory,
# gitignored) and prints one live dot stream. The dependency runs the other way from the
# comment above and that is fine — this game already leans on the framework for
# everything; the framework leaning on the game is what it must never do.
require_relative "../../tools/parallel_test"

namespace :test do
  desc "Run this game's suite across processes (rake test:parallel JOBS=8)"
  task :parallel do
    ParallelTest.run(FileList["test/**/test_*.rb"].to_a)
  end
end

desc "Build wolf3d.gba"
task :build do
  ruby "wolf3d.rb"
end

task default: :test
