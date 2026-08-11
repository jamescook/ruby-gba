# frozen_string_literal: true

require "digest"

module RubyGBA
  module Calibration
    # WHAT A SET OF WEIGHTS WAS MEASURED ON, recorded so that a later tree can be asked whether
    # it still matches.
    #
    # THE FAILURE THIS EXISTS FOR. The weights file says to re-run the calibration after
    # changing the lowering of a priced op, and nothing checked that anybody had. A change to
    # the shape of a loop left three weights describing a loop shape their benchmarks no longer
    # got, and that sat in the file across several commits before anyone noticed — found by
    # accident, while re-measuring something else.
    #
    # WHY NOT HASH THE SOURCE FILES. The set of files a weight depends on is "whatever changes
    # the bytes of its benchmark cartridge": the lowering, the assembler, the surface a
    # benchmark builds through, the ROM header. That is most of the library. A digest over it
    # would fire on every refactor that changed nothing, and the learned answer to a guard that
    # cries wolf is to re-run, watch nothing move, and commit — which teaches people to skip it.
    #
    # SO HASH THE CARTRIDGES. The emulator is deterministic: a cartridge whose bytes have not
    # changed cannot read differently, and one whose bytes have changed may. The bytes are the
    # complete and exact input to a reading, so a digest of them has no false alarms and misses
    # nothing that reaches a benchmarked op. It also puts the comparison on the INPUTS, which
    # are exact, rather than the outputs, which wander in the last digit — a residual like
    # blit_start moves whenever anything near it does, and comparing those would need a
    # tolerance nobody can justify.
    #
    # Checked against the tree by test_cost_calibration_tool.rb, which needs no emulator: it
    # rebuilds every cartridge and compares. What it CANNOT do is say what a weight became —
    # only that its cartridge changed, which is the cue to re-run the tool and read the numbers.
    module Provenance
      # The emulator's own sources. A change here leaves every cartridge byte-identical and
      # every weight stale, which is the one blind spot the cartridges have. The tests are left
      # out on purpose: they check the probe, they do not decide what it counts.
      #
      # Not covered, and worth knowing: the system libmgba the extension links against. Its
      # path and build differ per machine, so hashing it would make this fire on a colleague's
      # laptop rather than on a change.
      EMULATOR_SOURCES = %w[
        gemba-core/ext/gemba_core_ext/extconf.rb
        gemba-core/ext/gemba_core_ext/gemba_core_ext.c
        gemba-core/ext/gemba_core_ext/gemba_core_ext.h
        gemba-core/lib/gemba_core.rb
        gemba-core/lib/gemba_core/probe.rb
        gemba-core/lib/gemba_core/version.rb
      ].freeze

      ROOT = File.expand_path("../..", __dir__)

      # One digest over all of them, in the order above — a list rather than a glob so that a
      # file appearing or vanishing is a deliberate edit here and not a silent change of
      # meaning.
      def self.emulator_digest
        sha = Digest::SHA256.new
        EMULATOR_SOURCES.each { |path| sha.update(File.binread(File.join(ROOT, path))) }
        sha.hexdigest
      end

      # A measurer that also records the cartridge each reading was taken ON, by content, and
      # passes the reading straight through.
      #
      # It wraps whatever measurer it is given rather than being one, so the same code records
      # the real run (which needs the emulator) and the check (which does not) — one
      # implementation, and no way for the two to disagree about what was built.
      class Log
        attr_reader :digests

        def initialize(measurer)
          @measurer = measurer
          @digests = {}
        end

        # The three clocks a benchmark can ask for. A cartridge read twice — once for the
        # instructions it ran and once for the time a transfer held the console frozen — is one
        # cartridge and hashes once.
        %i[busy stall total].each do |clock|
          define_method(clock) do |name, rom|
            @digests[name] = Digest::SHA256.hexdigest(rom.buffer)
            @measurer.public_send(clock, name, rom)
          end
        end
      end
    end
  end
end
