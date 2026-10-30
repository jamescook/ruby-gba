# frozen_string_literal: true

require "test_helper"

require "conformance_fixture"

# The coverage guard on the Advance's lowering: the kitchen-sink fixture lowers to a clean
# cartridge, raw bytes go into it verbatim, and the lowering describes a declared asset the way
# the interpreter does. That the fixture covers every kind is in
# test/all/vblank/ir/test_cross_backend_conformance.rb.
class TestCrossBackendConformanceCartridge < Minitest::Test
  ROMValidator = VBlank::Cartridge::ROMValidator

  def test_gba_backend_lowers_the_whole_fixture_to_a_clean_rom
    # A feature the GBA backend can't lower raises LoweringError; a structurally
    # bad ROM makes ROM.assemble (which validates the image) raise ROMError.
    # Neither may happen.
    code = GBA.new.lower(ConformanceFixture.program)
    rom = ROM.assemble(code, title: "CONFORM", code: "BCNF", maker: "01")

    assert ROMValidator.check(rom).ok?, "the lowered fixture must be a valid ROM"
  end

  # ---- the one hardware-only exception, pinned explicitly ----

  def test_raw_lowers_on_the_gba_backend
    nop = [0xE1A00000].pack("V")
    code = GBA.new.lower(VBlank::IR::Build.program(
      VBlank::IR::Build.screen(:bitmap),
      VBlank::IR::Build.raw(nop),
      VBlank::IR::Build.halt,
    ))
    assert_includes code, nop, "the GBA backend appends raw bytes verbatim"
  end

  # ---- both backends describe a declared asset the same way ----
  #
  # An image and a recorded sound are facts about the program, not about a machine, and both
  # backends have to know them. They each used to write that down for themselves, which is
  # two descriptions of one thing in the two places whose whole contract is that they agree.
  # Now IR::Assets reads the description off the declaring node, so the two cannot differ —
  # this holds them to it.
  def test_both_backends_describe_an_image_the_same_way
    program = asset_program
    Reference.new.run(program)
    gba = GBA.new
    gba.lower(program)

    assert_equal registry(Reference.new.tap { |r| r.run(program) }, :@bitmaps), gba.bitmaps
  end

  def test_both_backends_describe_a_recorded_sound_the_same_way
    program = asset_program
    gba = GBA.new
    gba.lower(program)

    # Both sides keep their samples in a mixer of their own — GBA::Mixer and Reference::Mixer —
    # so the same reach finds them on each.
    interpreted = Reference.new.tap { |r| r.run(program) }.instance_variable_get(:@mixer)

    assert_equal registry(interpreted, :@samples),
                 registry(gba.instance_variable_get(:@mixer), :@samples)
  end

  # A program that declares one of each and then stops.
  private def asset_program
    b = VBlank::IR::Build
    b.program(
      b.screen(:bitmap),
      b.bitmap(:art, width: 2, height: 2, pixels: "\x1F\x00\x00\x00\x00\x7C\xFF\x03", transparent: 0),
      b.sample(:clip, "\x00\x10\x20\x30", 8000, note: :E4),
      b.halt,
    )
  end

  private def registry(backend, name)
    backend.instance_variable_get(name)
  end
end
