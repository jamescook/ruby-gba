#!/usr/bin/env ruby
# frozen_string_literal: true

# WHICH EXAMPLES THE NATIVE LOWERING CAN WRITE AS C TODAY, and what each of the others is refused
# for. The native backend trails the other two (see atop IR::Backends), so this list is how far
# it has got, said by trying each example rather than by anybody keeping a note.
#
#   ruby tools/native_examples.rb
#
# prints one line an example: its file's name, a tab, and `builds` or the reason it is refused.
# Nothing is compiled: an example builds when the lowering writes its C without a refusal, which
# takes a moment where a compile takes seconds.
#
# It is its own program rather than something a test calls in-process, because finding the game
# an example declares means watching RubyGBA.game while the example loads, and that is a change
# to the whole process no test may make (test/ruby_gba/ir/backends/native/test_native_examples.rb
# runs this and reads what it prints).
require_relative "../lib/ruby_gba"

module NativeExamples
  EXAMPLES = RubyGBA.root.join("examples").to_s

  # Each game an example declares, noted as RubyGBA.game hands it back.
  module NoteGames
    def game(*, **, &)
      super.tap { |made| NativeExamples.declared << made }
    end
  end

  def self.declared = @declared ||= []

  # [the example's name, nil when it builds or the reason it does not], for every example.
  def self.verdicts
    RubyGBA.singleton_class.prepend(NoteGames)
    Dir.glob(File.join(EXAMPLES, "*.rb")).sort.map do |path|
      [File.basename(path, ".rb"), refusal_after_loading(path)]
    end
  end

  def self.refusal_after_loading(path)
    before = declared.length
    require path
    games = declared[before..]
    return "declares no game through RubyGBA.game" if games.empty?

    native = RubyGBA::IR::Backends::Native.new
    games.each { |game| native.lower(native.checked_program(game, err: nil)) }
    nil
  rescue StandardError, ScriptError => e
    e.message.lines.first.strip
  end
end

if $PROGRAM_NAME == __FILE__
  NativeExamples.verdicts.each { |name, refusal| puts "#{name}\t#{refusal || 'builds'}" }
end
