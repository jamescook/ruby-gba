# frozen_string_literal: true

# WHICH FILES EACH RUN OF THIS SUITE LOADS, in one place, so the Rakefile and the tests read the
# same answer. Which run is going is the library's to say (VBlank::Testing.lowering), as it is
# for a game's own suite.
#
# Every run is a lowering playing games as one console (VBlank::Testing::Lowering::RUNS), and the
# folder a test file sits in says which runs load it:
#
#   test/all/                  what a game does, asked through `game_player`: every run
#   test/console/<console>/    what only that console's hardware can do: every run that plays
#                              games as that console
#   test/lowering/<lowering>/  that lowering's own output — the ARM, the C, the cartridge read
#                              back in the emulator: that lowering's run
#   test/interpreter/          what only the interpreter answers — its step budget, its count of
#                              steps, a pass told to take several frames: the run whose player
#                              is the interpreter, since every other run's player is a lowered
#                              game checked against it
#
# A NEW TEST GOES IN test/all/. One that fails on a run whose console cannot do what it asks is
# written again for each run that can, in that console's or that lowering's folder, with the
# game it plays kept once in a module both include. Each folder mirrors lib/ inside it.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  ALL_DIR = "test/all"
  INTERPRETER_DIR = "test/interpreter"

  # The folder of +console+'s own tests, and of +lowering+'s.
  def self.console_dir(console) = "test/console/#{console}"
  def self.lowering_dir(lowering) = "test/lowering/#{lowering}"

  # THE FOLDERS EACH LOWERING OWNS: its own, and for the run whose player is the interpreter the
  # interpreter's. Only that lowering's run loads them.
  LOWERING_FOLDERS = Ractor.make_shareable(VBlank::Testing::Lowering::RUNS.to_h do |run|
    own = [lowering_dir(run.name)]
    own << INTERPRETER_DIR unless run.checked?
    [run.name, own]
  end)

  # THE FOLDER EACH CONSOLE OWNS, loaded by every run that plays games as that console (the
  # Advance's by the GBA lowering's run and by the native, JavaScript and Ruby runs playing as the
  # Advance) and by no other. test/all is nobody's, so every run loads it.
  CONSOLE_FOLDERS = Ractor.make_shareable(VBlank::Testing::Lowering::RUNS.map(&:console).uniq.to_h do |console|
    [console, [console_dir(console)]]
  end)

  NATIVE_DIR = "#{lowering_dir(:native)}/vblank/ir/backends/native".freeze

  # The test of the program a player runs, with its window. It builds with SDL, whose first build
  # fetches its source over the network, so it is loaded only when asked (SDL=1).
  DESKTOP_TEST = Ractor.make_shareable("#{NATIVE_DIR}/test_native_desktop.rb")

  module_function

  # Every test file of the suite, and the desktop test only when +desktop+. The Rakefile hands
  # these, LOWERING_FOLDERS and CONSOLE_FOLDERS to the library's rake tasks, which leave out of
  # each run the folders it does not own (VBlank::Testing::Lowering.files_for).
  def all_files(desktop: false)
    found = Dir.glob("test/**/test_*.rb").sort - ["test/test_helper.rb"]
    desktop ? found : found - [DESKTOP_TEST]
  end
end
