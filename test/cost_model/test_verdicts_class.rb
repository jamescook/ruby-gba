# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Verdicts (lib/ruby_gba/ir/cost_model/verdicts.rb) as a standalone class. #looping?
# and #buffered? need nothing but the program itself, so they're exercised with the
# other collaborators left nil — proof the constructor doesn't force dependencies a
# given method never touches.
class TestVerdictsClass < CostModelTest
  Verdicts = RubyGBA::IR::CostModel::Verdicts

  def bare_verdicts
    Verdicts.new(weights: WEIGHTS, catalogue: nil, walker: nil, pricing: nil, fast_frame: false,
                fast_interrupts: false)
  end

  def test_looping_is_true_only_for_a_program_with_a_game_loop
    static = program { screen :bitmap; halt }
    looping = program { screen :bitmap; game_loop { halt } }

    v = bare_verdicts
    refute v.looping?(static)
    assert v.looping?(looping)
  end

  def test_buffered_reads_off_the_screens_own_declaration
    plain = program { screen :bitmap; halt }
    torn_free = program { screen :bitmap, tear_free: true; halt }

    v = bare_verdicts
    refute v.buffered?(plain)
    assert v.buffered?(torn_free)
  end
end
