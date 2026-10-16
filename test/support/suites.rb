# frozen_string_literal: true

# WHICH FILES EACH LOWERING'S RUN OF THIS SUITE LOADS, in one place, so the Rakefile and the
# tests read the same answer. Which lowering a run tests is the library's to say
# (RubyGBA::Testing.lowering), as it is for a game's own suite.
#
# Every test is played by both, but for the tests in a folder one lowering owns
# (LOWERING_FOLDERS), which only that lowering's run loads. So a new test that does not pass on
# both lowerings fails `rake test`, with nothing to write to say where it runs.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  NATIVE_DIR = "test/ruby_gba/ir/backends/native"

  # THE FOLDERS THAT BELONG TO ONE LOWERING. A test there is about that lowering's own output —
  # the ARM a cartridge is made of, the cartridge played in the emulator, the C the native
  # lowering writes — and the other lowering's run never loads it. Every test outside them is
  # about the game, and every lowering's run loads it. Each folder mirrors a part of lib that is
  # that lowering's alone: the GBA backend; the diagnostics, which read back a finished
  # cartridge; the playthroughs, which drive one in the emulator; and the native backend.
  LOWERING_FOLDERS = Ractor.make_shareable({
                                             gba: ["test/ruby_gba/ir/backends/gba", "test/ruby_gba/diagnostics",
                                                   "test/ruby_gba/playthroughs"],
                                             native: [NATIVE_DIR]
                                           })

  # The test of the program a player runs, with its window. It builds with SDL, whose first build
  # fetches its source over the network, so it is loaded only when asked (SDL=1).
  DESKTOP_TEST = Ractor.make_shareable("#{NATIVE_DIR}/test_native_desktop.rb")

  module_function

  # Every test file of the suite, and the desktop test only when +desktop+. The Rakefile hands
  # these and LOWERING_FOLDERS to the library's rake tasks, which leave out of each lowering's run
  # the other lowering's folders (RubyGBA::Testing::Lowering.files_for).
  def all_files(desktop: false)
    found = Dir.glob("test/**/test_*.rb").sort
    desktop ? found : found - [DESKTOP_TEST]
  end
end
