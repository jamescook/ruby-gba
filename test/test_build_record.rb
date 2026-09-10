# frozen_string_literal: true

require "test_helper"

require "stringio"

# What the build worked out about a cartridge, and how it gets there. A ROM used to be
# assembled and then filled in field by field from outside, so there was a moment when it
# was a valid cartridge and half a report. These pin that a ROM is one or the other.
class TestBuildRecord < Minitest::Test
  def a_built_rom
    RubyGBA.build("RECORD", code: "ZREC", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      clear_screen :black
      t = var :t, 0
      game_loop do
        repeat(50) { |i| t.add i }
        fill_rect 0, 0, 40, 8, :green
      end
    end
  end

  # A cartridge and a report about how it was made are two different things, and only one
  # of them is in the bytes. Assembling machine code from anywhere else gives the first.
  def test_a_cartridge_assembled_from_machine_code_knows_nothing_about_how_it_was_built
    program = RubyGBA::IR::Build.program(RubyGBA::IR::Build.screen(:bitmap),
                                         RubyGBA::IR::Build.clear_screen(:black),
                                         RubyGBA::IR::Build.halt)
    rom = RubyGBA::ROM.assemble(GBA.new.lower(program), title: "RAW", code: "ZRAW", maker: "01")

    assert_nil rom.built
    assert_nil rom.source_program
    assert_nil rom.placement
  end

  # ...and it says so rather than guessing. Every default the estimate would fall back on is
  # the safe, dearer one, so a report built on them reads plausibly and is wrong by nearly
  # the factor the quick memory is worth — with nothing on the page to say which it was.
  def test_a_cartridge_that_cannot_report_on_itself_refuses_rather_than_guessing
    rom = RubyGBA::ROM.new(title: "RAW", code: "ZRAW", maker: "01")

    %i[profile cost_model].each do |asking|
      error = assert_raises(RubyGBA::ROMError) { rom.public_send(asking, out: StringIO.new) }
      assert_match(/does not know how it was built/, error.message)
      assert_match(/RubyGBA\.build/, error.message)
    end
  end

  # A built one answers all of it, and there is no way to have some of it: the record is
  # made whole by the backend and handed over at assembly.
  def test_a_built_cartridge_carries_everything_the_build_worked_out
    rom = a_built_rom

    refute_nil rom.built
    assert_equal rom.source_program, rom.built.source_program
    refute_empty rom.placement.funcs, "this program has something worth keeping in quick memory"
    assert_includes rom.var_addresses.keys, :t
    refute_empty rom.loop_shapes
    refute_nil rom.palette_entries
    refute_nil rom.compression
    assert_equal({ fast_cartridge: true, fast_code: true }, rom.build_options)
  end

  # ...including what it was TOLD, because measuring a cartridge means building it again the
  # same way, and a ROM built with different settings has a frame rate the shipped one does not.
  def test_a_built_cartridge_remembers_the_options_it_was_built_with
    rom = RubyGBA.build("SLOW", code: "ZSLW", maker: "01", fast_code: false, fast_cartridge: false,
                                out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop { fill_rect 0, 0, 40, 8, :green }
    end

    assert_equal({ fast_cartridge: false, fast_code: false }, rom.build_options)
  end

  # The half that used to be settable is not any more. A ROM cannot be talked into being
  # half a report after the fact.
  def test_nothing_can_fill_a_cartridge_in_afterwards
    rom = RubyGBA::ROM.new(title: "RAW", code: "ZRAW", maker: "01")

    %i[source_program= placement= var_addresses= loop_shapes= palette_entries= compression=].each do |setter|
      refute_respond_to rom, setter
    end
  end

  # The estimate reads the record rather than six fields, and what it reads has to be the
  # build's own answer: a routine kept in quick memory is charged less, and being wrong
  # about that is the one mistake that moves the whole report.
  def test_the_estimate_is_told_which_routines_the_build_kept_in_quick_memory
    rom = a_built_rom
    told = rom.built.for_cost_model

    assert_equal rom.placement, told[:placement]
    assert told[:fast_frame], "the game loop's own body moved, and the estimate is told so"
    assert_equal rom.var_addresses, told[:var_addresses]
    assert_equal rom.loop_shapes, told[:loop_shapes]
  end
end
