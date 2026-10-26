# frozen_string_literal: true

require "digest"
require "fileutils"

# ONE WHOLE TEST RUN ON THE MACHINE AT A TIME. Each lowering's run — the GBA lowering's (which
# plays cartridges in the emulator) and the native lowering's (which builds every game as C) — is
# sized to use the machine, and two at once take twice as long each and slow everything else
# besides. So a whole run takes this lock first, once for both lowerings when `rake test` plays
# them in turn, and one that finds it held waits, saying which run it is waiting for and in which
# checkout. A run of one file (TEST=) does not take it: it is short, and it is what somebody
# working on one thing runs over and over.
#
# The lock is the operating system's lock on a file, so it lets go when the run that holds it
# ends, however it ends. By default it is one file in the home folder, shared by every checkout,
# since what it guards is the machine — and not in the temporary folder, which a sandboxed session
# can be given one of its own.
#
# TWO CHECKOUTS AT ONCE. Somebody with two checkouts of the repository (a worktree for each piece
# of work, or two sessions) can let each take a lock of its own, so neither waits on the other:
# start the run with VBLANK_SUITE_LOCK=checkout. The two then share the machine's cores, and each
# takes about twice as long as it would alone. Two runs in the same checkout still wait for each
# other. VBLANK_SUITE_LOCK=machine, or nothing, is the shared lock.
module SuiteLock
  FOLDER = Ractor.make_shareable(File.join(Dir.home, ".cache", "vblank"))
  PATH = Ractor.make_shareable(File.join(FOLDER, "test-suites.lock"))

  module_function

  # The lock a run takes: the machine's, or with +setting+ "checkout" one for the checkout at
  # +checkout+ alone, kept beside the machine's and named for the checkout's folder.
  def chosen_path(setting, checkout:)
    case setting
    when nil, "", "machine" then PATH
    when "checkout"
      folder = File.expand_path(checkout)
      File.join(FOLDER, "test-suites-#{File.basename(folder)}-#{Digest::SHA256.hexdigest(folder)[0, 12]}.lock")
    else
      raise ArgumentError, "VBLANK_SUITE_LOCK is \"machine\" or \"checkout\", not #{setting.inspect}. " \
                           "Leave it out to share one lock with every checkout on this machine."
    end
  end

  # Waits for whoever holds the lock, then holds it for the run called +what+, and hands back the
  # open file: the lock lasts as long as that is open.
  def hold(what, path: PATH, io: $stdout)
    FileUtils.mkdir_p(File.dirname(path))
    file = File.open(path, File::RDWR | File::CREAT, 0o644)
    unless file.flock(File::LOCK_EX | File::LOCK_NB)
      holder = file.read.strip
      io.puts "Waiting for another whole test run on this machine to finish: #{holder.empty? ? 'one just starting' : holder}"
      io.puts "If that run is in another checkout, start this one with VBLANK_SUITE_LOCK=checkout to run beside it, " \
              "sharing the cores."
      io.flush
      file.flock(File::LOCK_EX)
    end
    file.truncate(0)
    file.rewind
    file.write("#{what} in #{Dir.pwd} (process #{Process.pid})")
    file.flush
    file
  end
end
