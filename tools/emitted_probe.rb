# frozen_string_literal: true

# The child half of `rake emitted` (see tools/emitted.rb): build ONE example
# against ONE copy of the library and print what it emitted, as a line of JSON.
#
#   ruby tools/emitted_probe.rb <lib root> <repo root> <example.rb>
#
# It runs in its own process so the two libraries being compared never meet, and
# so one example that blows up can't take the rest of the run down with it.
#
# Two rules keep it honest:
#
# 1. It measures with whatever the library at <lib root> already offers, and never
#    with anything added for its benefit. That is what lets it run against an old
#    commit — a probe that needed a method landing today could only ever compare
#    today against today. Anything the older library can't answer is reported as
#    unknown rather than failing the run.
#
# 2. It builds the WORKING TREE's example against that library. The pairing is the
#    whole measurement: hold the game fixed, change the compiler, and the
#    difference is the compiler's. Get it backwards and an edited example scores
#    as a compiler change.

lib_root, repo_root, example = ARGV
abort "usage: emitted_probe.rb <lib root> <repo root> <example.rb>" unless example

$LOAD_PATH.unshift File.expand_path(lib_root)
require "ruby_gba"
require "json"
require "stringio"

# An example asks for the library by relative path (`require_relative
# "../lib/ruby_gba"`), which would load the working tree's copy straight over the
# one we just chose — silently comparing today against today. Marking that file as
# already loaded turns the example's require into the no-op it should be.
working_tree_entry = File.join(repo_root, "lib", "ruby_gba.rb")
$LOADED_FEATURES << File.realpath(working_tree_entry) if File.exist?(working_tree_entry)

report = { name: File.basename(example, ".rb") }

begin
  # An example is free to print, and its output would land in the middle of the
  # JSON this writes. Give it somewhere else to print to.
  real_stdout = $stdout
  $stdout = StringIO.new

  known = RubyGBA.registered_games.size
  load File.expand_path(example)
  game = RubyGBA.registered_games[known..].last
  raise "no RubyGBA.game was declared" unless game

  program = game.program
  backend = RubyGBA::IR::Backends::GBA.new
  emitted = backend.lower(program)

  # Where the code stops and the embedded assets start. The blobs (tile pictures,
  # maps, sound samples) are laid down after all the code, so the first one's
  # position is the boundary. Reading it off the backend's own bookkeeping is
  # nosy, but it is long-standing bookkeeping, which is what an older library can
  # answer too.
  positions = backend.instance_variable_get(:@data_positions) || {}
  code_bytes = positions.values.min || emitted.bytesize

  report[:title] = game.title
  report[:code] = code_bytes
  report[:data] = emitted.bytesize - code_bytes

  # Size and speed move independently — an op can cost thirty instructions of ROM
  # and nothing per frame — so carry the frame estimate alongside. It is a
  # separate question, so a library that can't answer it still gets measured.
  begin
    report[:frame] = RubyGBA::IR::CostModel.new.as_json(program)[:frame_cost]
  rescue StandardError, ScriptError
    report[:frame] = nil
  end
rescue StandardError, ScriptError => e
  report[:error] = "#{e.class}: #{e.message.lines.first.to_s.strip}"
ensure
  $stdout = real_stdout
end

puts JSON.generate(report)
