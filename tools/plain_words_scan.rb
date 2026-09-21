# frozen_string_literal: true

require "ripper"
require_relative "../lib/ruby_gba"

# WHAT A BUILD IS ALLOWED TO CALL THE CONSOLE'S QUICK MEMORY, checked over the whole library.
#
# The framework teaches somebody who knows Ruby and does not know this console. So nothing it
# PRINTS may fall back on the hardware's own vocabulary — not "IWRAM", not "fast RAM". There
# is one name for it and {Messages::PlainWords::QUICK_MEMORY} holds it.
#
# COMMENTS ARE EXEMPT, and deliberately: a comment beside the lowering may name IWRAM outright,
# because that is where the hardware gets taught. This is about what a PERSON RUNNING A BUILD
# reads. Telling those two apart is the whole job, and it is why this reads the source through
# Ruby's own lexer rather than grepping: a grep cannot tell a comment from a message. It also
# means a sentence assembled out of two pieces never matches by accident, since what sits
# between them is not string content.
#
# A LINT, NOT A TEST. It asks a question about the source on disk, not about anything the
# library does when it runs — so it belongs in `rake plain_words` and the commit hook rather
# than in a suite whose job is to prove behaviour.
module PlainWordsScan
  LIB = File.expand_path("../lib", __dir__)

  Finding = Data.define(:file, :line, :text)

  module_function

  # Every piece of text the library could print, with where it was written.
  def literals(root = LIB)
    Dir[File.join(root, "**", "*.rb")].sort.flat_map do |path|
      Ripper.lex(File.read(path)).filter_map do |(line, _col), type, text, _state|
        next unless type == :on_tstring_content

        Finding.new(file: path.delete_prefix("#{root}/"), line: line, text: text)
      end
    end
  end

  # The ones that call it something else.
  def offenders(found = literals)
    banned = RubyGBA::Messages::PlainWords::NOT_CALLED.fetch(RubyGBA::Messages::PlainWords::QUICK_MEMORY)
    found.select { |one| banned.any? { |pattern| one.text.match?(pattern) } }
  end

  # A scan that read nothing would pass in silence, which is the one way a check like this is
  # worse than none at all. So it shows its work before it reports.
  def read_enough?(found) = found.length > 1000

  def run(out = $stdout)
    found = literals
    unless read_enough?(found)
      out.puts "plain words: the scan found only #{found.length} pieces of text — is it reading lib/?"
      return false
    end

    bad = offenders(found)
    if bad.empty?
      out.puts "plain words: #{found.length} pieces of text, all of them fine"
      return true
    end

    name = RubyGBA::Messages::PlainWords::QUICK_MEMORY
    out.puts "plain words: a build says #{name.inspect} and nothing else. Write " \
             "PlainWords::QUICK_MEMORY, or say it in a comment, where the hardware can be named."
    bad.each { |one| out.puts "  #{one.file}:#{one.line}  #{one.text.strip}" }
    false
  end
end

PlainWordsScan.run or exit 1 if $PROGRAM_NAME == __FILE__
