# frozen_string_literal: true

# WHICH LOWERING A RUN OF THE SUITE TESTS, and which files it loads, in one place, so the
# Rakefile and the tests read the same answer.
#
# A run tests ONE lowering, and `rake test` makes one run for each. The GBA lowering's
# (`rake test:lowering:gba`) plays every game on the interpreter (Backends::Reference) and checks
# the console through the emulator where a test asks for it; the native lowering's
# (`rake test:lowering:native`) plays them as C (Backends::Native), checked against the
# interpreter. Every test is played by both, but for the tests in a folder one lowering owns
# (LOWERING_FOLDERS), which only that lowering's run loads. So a new test that does not pass on
# both lowerings fails `rake test`, with nothing to write to say where it runs.
#
# Plain globbing rather than Rake's FileList, because a test that reads this runs in a Ractor
# and FileList reads a constant of rake's that a Ractor may not.
module TestSuites
  NATIVE_DIR = "test/ruby_gba/ir/backends/native"

  # The setting a run's lowering is read from. The native lowering's run sets it to "native";
  # nothing sets it to anything else, and left alone it is the GBA lowering's run.
  LOWERING_SETTING = "RUBY_GBA_LOWERING"
  LOWERINGS = %i[reference native].freeze

  # The lowering this run tests, read once when the suite loads.
  LOWERING = ENV.fetch(LOWERING_SETTING, "reference").to_sym
  unless LOWERINGS.include?(LOWERING)
    raise ArgumentError, "#{LOWERING_SETTING} is #{LOWERING}, and a run can test #{LOWERINGS.join(' or ')}"
  end

  # THE FOLDERS THAT BELONG TO ONE LOWERING. A test there is about that lowering's own output —
  # the ARM a cartridge is made of, the cartridge played in the emulator, the C the native
  # lowering writes — and the other lowering's run never loads it. Every test outside them is
  # about the game, and every lowering's run loads it. Each folder mirrors a part of lib that is
  # that lowering's alone: the GBA backend; the diagnostics, which read back a finished
  # cartridge; the playthroughs, which drive one in the emulator; and the native backend.
  LOWERING_FOLDERS = Ractor.make_shareable({
                                             reference: ["test/ruby_gba/ir/backends/gba", "test/ruby_gba/diagnostics",
                                                         "test/ruby_gba/playthroughs"],
                                             native: [NATIVE_DIR]
                                           })

  # The test of the program a player runs, with its window. It builds with SDL, whose first build
  # fetches its source over the network, so it is loaded only when asked (SDL=1).
  DESKTOP_TEST = Ractor.make_shareable("#{NATIVE_DIR}/test_native_desktop.rb")

  module_function

  def native? = LOWERING == :native

  # Every test file +lowering+'s run loads: all of them but those in another lowering's folders,
  # and the desktop test only when +desktop+.
  def files(lowering: LOWERING, desktop: false)
    others = LOWERING_FOLDERS.reject { |owner, _| owner == lowering }.values.flatten
    found = Dir.glob("test/**/test_*.rb").sort.reject { |path| others.any? { |dir| path.start_with?("#{dir}/") } }
    desktop ? found : found - [DESKTOP_TEST]
  end
end
