# frozen_string_literal: true

# Every constant a test class holds that a worker Ractor could not read, one per line.
#
# It runs as a process of its own, and that is the point rather than an accident. A test can
# only see the test classes loaded beside it, which under `rake test:parallel` is one shard's
# share of the suite — so a check written as an ordinary test would quietly cover a twelfth
# of what it claims to. This loads every test file and looks at all of them.
#
# Loading a test file is enough to declare its constants, which is all this needs. It must
# not go on to RUN them, so it leaves through exit! before minitest's own at_exit can.
#
# Called by test/ruby_gba/test_ractor_safety.rb. Printing nothing means everything is fine.
#
# NOT NAMED test_*.rb, and that matters: the suite is collected by globbing for that, so a
# name like it would be loaded as a test file — and this one leaves through exit!, which
# would end that shard's run early and silently.
#
# It declares no constants of its own either. It loads every test file in the suite, so any
# name it put at the top level could collide with one of theirs.

tests = File.expand_path("..", __dir__)
$LOAD_PATH.unshift tests

require "test_helper"

Dir[File.join(tests, "**", "test_*.rb")].sort.each do |path|
  require path
rescue StandardError, ScriptError => e
  warn "could not load #{path.delete_prefix("#{tests}/")}: #{e.class}: #{e.message.lines.first}"
end

# Minitest's own classes are in the list, and three of their constants cannot be read from a
# worker either. That belongs to whoever runs the suite in Ractors, not to this suite.
ours = Minitest::Runnable.runnables.reject { |klass| klass.name.to_s.start_with?("Minitest::") }

(ours + [SharedConstants]).each do |holder|
  holder.constants(false).each do |name|
    value = holder.const_get(name, false)
    next if value.is_a?(Module) || Ractor.shareable?(value)

    puts "#{holder}::#{name}  (#{value.class})"
  end
end

$stdout.flush
exit! 0
