# frozen_string_literal: true

require "fileutils"

# ONE WHOLE TEST RUN ON THE MACHINE AT A TIME. Each lowering's run — the GBA lowering's (which
# plays cartridges in the emulator) and the native lowering's (which builds every game as C) — is
# sized to use the machine, and two at once take twice as long each and slow everything else
# besides. So a whole run takes this lock first, once for both lowerings when `rake test` plays
# them in turn, and one that finds it held waits, saying which run it is waiting for. A run of one file (TEST=) does not take it: it is short, and it is what somebody
# working on one thing runs over and over.
#
# The lock is the operating system's lock on a file, so it lets go when the run that holds it
# ends, however it ends. It is one file in the home folder, shared by every checkout, since what
# it guards is the machine — and not in the temporary folder, which a sandboxed session can be
# given one of its own.
module SuiteLock
  PATH = File.join(Dir.home, ".cache", "ruby-gba", "test-suites.lock")

  module_function

  # Waits for whoever holds the lock, then holds it for the run called +what+, and hands back the
  # open file: the lock lasts as long as that is open.
  def hold(what, path: PATH, io: $stdout)
    FileUtils.mkdir_p(File.dirname(path))
    file = File.open(path, File::RDWR | File::CREAT, 0o644)
    unless file.flock(File::LOCK_EX | File::LOCK_NB)
      holder = file.read.strip
      io.puts "Waiting for another whole test run on this machine to finish: #{holder.empty? ? 'one just starting' : holder}"
      io.flush
      file.flock(File::LOCK_EX)
    end
    file.truncate(0)
    file.rewind
    file.write("#{what} (process #{Process.pid})")
    file.flush
    file
  end
end
