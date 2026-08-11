# frozen_string_literal: true

# Calibrate the cost model's per-op weights against the emulator's GBA timing model, and
# WRITE the result as a source-controlled Ruby fixture (lib/ruby_gba/ir/measured_weights.rb)
# that the cost model loads — no hand-copying, no JSON/YAML. The numbers are emulated-cycle
# counts, not host wall-clock time, so they are the same on any machine that runs this
# gemba-core build.
#
# Each weight is the cost, in scanlines, the model charges for one op. We measure the real
# thing: build a ROM whose per-frame loop does an op a known number of times, run it on the
# emulator (gemba-core), and read the cycles it actually burns per frame. Differencing two
# ROMs that differ only in the op under test cancels the fixed per-frame overhead — the game
# loop, the vblank wait, the repeat counter — leaving the op's marginal cost. The measurement
# is only valid while a frame's work fits inside a frame (~228 scanlines); past that the
# reading caps and wobbles, so the sizes are kept well under it and every reading is re-read
# to confirm.
#
# This file is only the driver. The work lives in tools/calibration/, split so that the parts
# which are not measurement can be tested without an emulator:
#
#   Benchmarks         builds the ROMs — one method per scenario
#   Measurer           the one seam to the emulator (FakeMeasurer stands in, in tests)
#   Reductions         the arithmetic that turns readings into a rate — pure functions
#   Calibrator         the recipes: which readings make which weight, and its Domain
#   Provenance         records WHAT each reading was taken on, so a later tree can be asked
#                      whether the committed weights still describe it
#   WeightsFixture     renders the result as the Ruby source of the fixture
#   CartridgesFixture  the same for the provenance
#
# Run it after changing the lowering of a priced op, then commit the diff:
#   ruby tools/calibrate_cost_model.rb
#
# You do not have to remember to: the suite rebuilds every cartridge and fails when they are
# no longer the ones the committed weights were measured on.

require_relative "../lib/ruby_gba"
require_relative "calibration/measurer"
require_relative "calibration/calibrator"
require_relative "calibration/provenance"
require_relative "calibration/weights_fixture"
require_relative "calibration/cartridges_fixture"

FIXTURE = File.expand_path("../lib/ruby_gba/ir/measured_weights.rb", __dir__)
CARTRIDGES = File.expand_path("calibration/measured_cartridges.rb", __dir__)

# The measurer, wrapped so that every cartridge it is handed is hashed on the way past.
log = RubyGBA::Calibration::Provenance::Log.new(RubyGBA::Calibration::Measurer.new)
calibration = RubyGBA::Calibration::Calibrator.new(log).run

# --- report what moved, against what is committed ---
current = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
puts format("%-20s %12s %12s %8s", "weight", "current", "measured", "ratio")
puts "-" * 56
calibration.weights.each do |name, value|
  was = current[name]
  puts format("%-20s %s %12.5f %s", name,
              was ? format("%12.5f", was) : format("%12s", "(new)"),
              value,
              was ? format("%7.2fx", value / was) : format("%8s", "-"))
end

File.write(FIXTURE, RubyGBA::Calibration::WeightsFixture.new(weights: calibration.weights,
                                                             domains: calibration.domains).render)
File.write(CARTRIDGES,
           RubyGBA::Calibration::CartridgesFixture.new(
             digests: log.digests, emulator: RubyGBA::Calibration::Provenance.emulator_digest
           ).render)
puts
puts "wrote #{calibration.weights.size} weights to #{FIXTURE.sub("#{Dir.pwd}/", '')}"
puts "wrote #{log.digests.size} cartridges to #{CARTRIDGES.sub("#{Dir.pwd}/", '')}"
