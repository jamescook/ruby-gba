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
#
# A NEW TEST GOES IN test/all/. One that fails on a run whose console cannot do what it asks is
# written again for each run that can, in that console's or that lowering's folder, with the
# game it plays kept once in a module both include. Each folder mirrors lib/ inside it.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  ALL_DIR = "test/all"

  # The folder of +console+'s own tests, and of +lowering+'s.
  def self.console_dir(console) = "test/console/#{console}"
  def self.lowering_dir(lowering) = "test/lowering/#{lowering}"

  # THE FOLDERS EACH RUN OWNS: its lowering's, and its console's. A folder several runs own (the
  # Advance's, by every run that plays games as the Advance) is loaded by each of them and by no
  # other run; test/all is nobody's, so every run loads it.
  LOWERING_FOLDERS = Ractor.make_shareable(VBlank::Testing::Lowering::RUNS.to_h do |run|
    [run.name, [lowering_dir(run.name), console_dir(run.console)]]
  end)

  NATIVE_DIR = "#{lowering_dir(:native)}/vblank/ir/backends/native".freeze

  # The test of the program a player runs, with its window. It builds with SDL, whose first build
  # fetches its source over the network, so it is loaded only when asked (SDL=1).
  DESKTOP_TEST = Ractor.make_shareable("#{NATIVE_DIR}/test_native_desktop.rb")

  module_function

  # Every test file of the suite, and the desktop test only when +desktop+. The Rakefile hands
  # these and LOWERING_FOLDERS to the library's rake tasks, which leave out of each run the
  # folders it does not own (VBlank::Testing::Lowering.files_for).
  def all_files(desktop: false)
    found = Dir.glob("test/**/test_*.rb").sort - ["test/test_helper.rb"]
    desktop ? found : found - [DESKTOP_TEST]
  end
end
