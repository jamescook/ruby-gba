# frozen_string_literal: true

# Coverage measurement is opt-in (COVERAGE=1 rake test) — plain `rake test`
# pays nothing for it. `rake test:parallel` runs the suite as several
# processes with no shared memory, so each one only records its own slice
# (SimpleCov.result, no report) and skips the HTML report; the Rakefile
# collates every shard's slice into one report once they've all exited.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  require_relative "support/coverage"

  sharded = ENV.key?("SHARD_FILES")
  SimpleCov.command_name "shard-#{Process.pid}" if sharded
  SimpleCov.start(&Coverage::FILTERS)
  SimpleCov.at_exit { SimpleCov.result } if sharded
end

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The one require a test file needs. It pulls in minitest and the library, and
# hands every test the names and helpers that nearly all of them want, so a test
# file can open with the thing it is actually testing.
#
# The short names below. A test says `Builder.new` and `Color.resolve(:red)`
# rather than spelling out RubyGBA::… every time. They used to be re-declared at
# the top of all 93 test files, which meant renaming one of them touched every
# file; now they live here.
#
# A file that wants a name for something else of its own just declares it — a
# constant in the file wins over one from here (test_cost_printer.rb points
# `Color` at the printer's palette that way).
module SharedConstants
  Reference = RubyGBA::IR::Backends::Reference # the oracle: runs a program in-process
  GBA = RubyGBA::IR::Backends::GBA             # the lowering: turns a program into a ROM
  Builder = RubyGBA::Builder                   # the DSL surface
  Color = RubyGBA::Graphics::Color
  ROM = RubyGBA::Cartridge::ROM

  # A solid 8x8 tile of one color — the piece of art a tiled test needs before it can say
  # anything about scrolling, layers, collision or sprites. Twenty-six files had written it
  # out for themselves, under five different names and in two spellings that differed by a
  # trailing newline, so a test reading two of them was comparing things that were not quite
  # the same. It is here once now.
  #
  # Shareable, like everything else here: a test may run in a Ractor, and a worker can read a
  # constant only when nothing in it can change. See test/ruby_gba/test_ractor_safety.rb.
  SOLID_TILE = Ractor.make_shareable((["########"] * 8).join("\n"))
end

# Every IR node class by its bare name, so a test that builds a tree by hand says
# `Case.new(clauses: ...)` rather than spelling out the namespace each time.
#
# OPT-IN, like the other narrower helpers: there are eighty-odd of these and some of the
# names are ones a test may want for something else (Table, Sample, Screen). A file that
# builds nodes directly includes it; everything else never sees them.
module NodeTypes
  RubyGBA::IR::Nodes.constants.each do |name|
    const_set(name, RubyGBA::IR::Nodes.const_get(name))
  end
end

# Shared helpers for tests that exercise the emulator in-process. The emulator backend
# (ruby-gba-emulator, a headless libmgba probe) is reached through RubyGBA::Diagnostics::Emulator — the one
# seam — so nothing here names it directly.
#
# Include this in a test class instead of copy-pasting begin/require/rescue
# blocks or per-test availability guards.
module EmulatorSupport
  # Whether the in-process emulator core can be loaded — for the standalone
  # debug scripts that degrade gracefully. Suite tests use #require_emulator!,
  # which fails loud, since the emulator is required, not optional.
  def self.gem_available?
    RubyGBA::Diagnostics::Emulator.available?
  end

  # Ensure the emulator is available, failing loudly if it isn't. It is required to verify
  # ROMs, so a missing build is a real error, not a reason to silently skip and pass with the
  # coverage gutted. `rake test` builds it first; run `rake test:emulator` to build it by hand.
  def require_emulator!
    RubyGBA::Diagnostics::Emulator.load!
  end

  # Lower an IR program to a finished ROM, the way the emulator tests need it — a
  # convenience over repeating ROM.assemble(GBA.new.lower(prog), title:, code:,
  # maker:) in every test. The header fields don't affect rendering, so they
  # default; pass +name+ just to label the ROM.
  #
  # The ROM carries its build record, so a test can ask the running cartridge about what the
  # build decided — what it is playing (Verifier#voices), where its variables are — without
  # holding on to the backend that lowered it.
  def assemble_rom(program, name: "TEST")
    backend = RubyGBA::IR::Backends::GBA.new
    code = backend.lower(program)
    RubyGBA::Cartridge::ROM.assemble(code, title: name, code: "TEST", maker: "01",
                                built: backend.build_record(program))
  end

  # Load +rom+ into the emulator and run it headless for +frames+ frames,
  # asserting it loads and runs without raising. Fails loudly if the emulator isn't
  # built (it's required). Returns a RubyGBA::Diagnostics::Verifier so callers can make pixel
  # assertions on the rendered frame:
  #
  #   v = assert_emulator_loads_rom(rom, frames: 30)
  #   assert v.red?(120, 80)
  def assert_emulator_loads_rom(rom, frames: 10, **opts)
    require_emulator!
    verifier = RubyGBA::Diagnostics::Verifier.new(rom, frames: frames, **opts)
    verifier.pixel(0, 0) # force the emulator to load the ROM and run the frames
    verifier
  rescue StandardError => e
    flunk "the emulator failed to load/run ROM after #{frames} frames: #{e.class}: #{e.message}"
  end
end

# Hand the above to every test, without each one asking.
#
# Reopening Minitest::Test is how a Minitest suite does what RSpec spells
# `config.include` — every test class already inherits from it, so a module
# included here reaches all of them. Ruby looks a constant up through the
# ancestors of the class it is used in, so `Reference` and `Color` resolve inside
# any test with nothing declared in the file.
#
# It IS a monkey-patch of somebody else's class, which is worth knowing. The
# alternatives are a base class every test has to remember to inherit from, or
# the per-file boilerplate this replaces. RSpec effectively does this too.
#
# Deliberately only the two that nearly every file wants. Narrower helpers stay
# opt-in — a file that needs `Differential` or `CostArith` includes it — so those
# names appear only where they are used and cannot collide across the suite.
class Minitest::Test # rubocop:disable Style/ClassAndModuleChildren
  include SharedConstants
  include EmulatorSupport

  # EVERY FIXTURE A TEST CLASS PARKS IN A CONSTANT IS FROZEN, ALL THE WAY DOWN, the moment it
  # is declared. Ruby tells a class when a constant is added to it, so there is nothing to
  # remember and nothing to repeat: this is the whole rule, in one place.
  #
  # It buys two things. A fixture shared by the tests in a file can no longer be changed by
  # one of them and read changed by the next — a real bug that is invisible until the day
  # test order moves. And it makes the suite runnable in a Ractor, which is Ruby's way of
  # using several cores at once: a worker may read a constant only when nothing in it can
  # change.
  #
  # Doing it by hand did not work, and the evidence is in the tree it replaced. Twenty-six
  # files had written out the same tile of art, and four of them wrote
  # `(("#" * 8) + "\n").freeze * 8` — where the freeze lands on the inner string and the
  # multiplication then makes a fresh unfrozen one. The intent was there and the result was
  # not, in four files, for years.
  #
  # TWO THINGS ARE LEFT ALONE. A nested module or class, because that is code rather than a
  # fixture. And a STREAM — a file, a socket, $stdout — because freezing one of those works,
  # and then nothing can write to it again: a test that parked $stdout in a constant would
  # take the whole run down, from here, with an error pointing somewhere else entirely.
  #
  # Anything that refuses to freeze is left exactly as it was and named by
  # test/ruby_gba/test_ractor_safety.rb rather than passing quietly. Only one thing does
  # refuse: a block that reaches for a variable around it, which can never be shared.
  # That is the one error caught here — anything else raising is a mistake in this method
  # and should be heard.
  #
  # Freezing a block hands back a new one rather than changing the old, so that case has to
  # put the constant back. That re-enters here, and stops on the first line.
  def self.const_added(name)
    value = const_get(name, false)
    return if value.is_a?(Module) || value.is_a?(IO) || Ractor.shareable?(value)

    shareable = Ractor.make_shareable(value)
    return if shareable.equal?(value)

    remove_const(name)
    const_set(name, shareable)
  rescue Ractor::IsolationError
    nil
  end
end
