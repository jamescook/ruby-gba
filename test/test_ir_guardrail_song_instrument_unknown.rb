# frozen_string_literal: true

require "test_helper"

# A song part names the instrument it plays, and the instrument is declared elsewhere. A name
# with no declaration behind it — a typo, or a forgotten `instrument` — stops the build with the
# name, rather than failing deep in the lowering.
class TestSongInstrumentUnknownGuardrail < Minitest::Test
  include RubyGBA::IR::Build

  Check = RubyGBA::IR::Guardrails::Checks::SongInstrumentUnknown

  def tune(instrument)
    song(:tune, total_frames: 4,
                voices: [RubyGBA::Music::Part.new(events: [[0, 262]], instrument: instrument)])
  end

  def clip = sample(:piano, [0, 60, 0, -60].pack("c*"), 8000)

  def test_a_part_that_plays_an_undeclared_instrument_stops_the_build
    findings = Check.new.detect(program(tune(:pinao), clip))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/:pinao/, findings.first.message)
  end

  def test_a_declared_instrument_is_quiet
    assert_empty Check.new.detect(program(tune(:piano), clip))
  end

  def test_a_square_wave_part_names_no_instrument
    assert_empty Check.new.detect(program(song(:tune, events: [[0, 262]], total_frames: 4)))
  end
end
