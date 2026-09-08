# frozen_string_literal: true

require "digest"

# Did `rake cost:check` actually run against the code as it stands?
#
#   ruby tools/cost_stamp.rb check    # for the pre-commit hook: 0 if nothing to do or the
#                                     # stamp is current, 1 if the check is owed
#   ruby tools/cost_stamp.rb write    # what the rake tasks call when the check passes
#
# WHY A STAMP AND NOT JUST A RULE. Which changes need the corpus re-measured is written down
# in .claude/rules/testing.md, and a written rule is remembered most of the time, which is
# not the same as always. This makes the machine remember: touch something that moves the
# estimate, and the commit stops until the corpus has been scored against it.
#
# WHY NOT JUST RUN THE CHECK IN THE HOOK. It needs the emulator, which a pure-Ruby install
# does not have, and ten seconds on every commit that brushes an example is the kind of tax
# people route around with --no-verify — after which the hook guards nothing. The stamp is
# instant, needs nothing installed, and asks only that the check was run once for this code.
#
# WHAT THE STAMP MEANS, precisely: the check passed while these files held exactly this
# content. It is a digest of the files that can move a reading, so editing any of them makes
# it stale and nothing else does. It is not a signature and not a security boundary — a
# person who wants to commit past it can, and the message says how.
module CostStamp
  ROOT = File.expand_path("..", __dir__)
  PATH = File.join(ROOT, "tools", ".cost_stamp")

  # The files whose contents can change what a frame costs, or what the corpus reads.
  #
  # The lowering is in here because it decides what the emitted code does, so it moves the
  # console's half of every reading. The examples are in here because the baseline holds a
  # row per example: edit one and its recorded ratio is about a program that no longer
  # exists. That does mean a comment-only edit to an example asks for ten seconds, which is
  # the price of not having to judge, file by file, whether an edit was "really" cosmetic.
  WATCHED = [
    "lib/ruby_gba/ir/cost_model.rb",
    "lib/ruby_gba/ir/cost_model/**/*.rb",
    "lib/ruby_gba/ir/measured_weights.rb",
    "lib/ruby_gba/ir/backends/gba.rb",
    "lib/ruby_gba/ir/backends/gba/**/*.rb",
    "examples/*.rb",
    "tools/cost_accuracy.rb",
    "tools/cost_accuracy_baseline.rb",
    "tools/cost_accuracy_baseline.json",
  ].freeze

  module_function

  def files
    WATCHED.flat_map { |pattern| Dir[File.join(ROOT, pattern)] }.uniq.sort
  end

  # One digest over every watched file: its path and its contents, so a rename counts as a
  # change and so the order two files were read in cannot matter.
  def digest
    sha = Digest::SHA256.new
    files.each do |path|
      sha << path.delete_prefix("#{ROOT}/")
      sha << "\0"
      sha << File.binread(path)
      sha << "\0"
    end
    sha.hexdigest
  end

  def write(path = PATH)
    File.write(path, "#{digest}\n")
  end

  def current?(path = PATH)
    File.read(path).strip == digest
  rescue Errno::ENOENT
    false
  end

  # Which watched files are staged for this commit — the reason the hook is speaking, so it
  # can say so rather than leaving the author to guess what tripped it.
  def staged
    names = `git -C #{ROOT} diff --cached --name-only --diff-filter=ACMR`.lines.map(&:chomp)
    watched = files.map { |path| path.delete_prefix("#{ROOT}/") }
    names & watched
  end

  def check(out: $stderr)
    reasons = staged
    return true if reasons.empty? || current?

    out.puts "This commit changes something that moves the cost estimate:"
    reasons.first(6).each { |name| out.puts "  #{name}" }
    out.puts "  ...and #{reasons.length - 6} more" if reasons.length > 6
    out.puts
    out.puts "Score the corpus against it before committing:"
    out.puts "  rake cost:check      (about 10s — fails if any example drifted further off)"
    out.puts "  rake cost:record     (if the move was meant; commit the JSON diff too)"
    out.puts
    out.puts "No emulator, or this really is cosmetic? SKIP_COST_CHECK=1 git commit ..."
    false
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.first
  when "write" then CostStamp.write
  when "check" then exit(CostStamp.check ? 0 : 1)
  else
    warn "usage: cost_stamp.rb check|write"
    exit 2
  end
end
