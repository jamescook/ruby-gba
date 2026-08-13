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

desc "Build wolf3d.gba"
task :build do
  ruby "wolf3d.rb"
end

task default: :test
