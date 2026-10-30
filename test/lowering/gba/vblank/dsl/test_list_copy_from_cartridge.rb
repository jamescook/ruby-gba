# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/dsl/test_list_copy_from"

# `list.copy_from` on the Advance's cartridge: the runs it copies, read in the emulator, and what
# eighteen of them cost a frame, measured by its profiler. What the copy does on every run is in
# test/all/vblank/dsl/test_list_copy_from.rb.
class TestListCopyFromCartridge < Minitest::Test
  include ListCopyFromGames

  private def on_console(game)
    rom = VBlank.build("COPYFROM", console: :gba, out: StringIO.new, err: StringIO.new, &game)
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)
    %i[first last held].map { |name| v.var(name) }
  end

  def test_a_run_from_a_worked_out_start_lands_the_same_on_both_backends
    assert_equal [LETTERS[5], LETTERS[8], 4], on_console(copying(start: 5))
  end

  # The console copies a whole word at a time, a half at a time, or a byte at a time, as the
  # run's start and length allow, so each width and an even and an odd start are each tried.
  def test_every_width_and_start_agrees_on_both_backends
    [[:byte, 8, 8], [:byte, 3, 6], [:half, 2, 4], [:half, 1, 3], [:word, 7, 5]].each do |width, start, count|
      game = copying(start: start, count: count, width: width)

      assert_equal [LETTERS[start], LETTERS[start + count - 1], count], on_console(game), "#{width} from #{start}"
    end
  end

  # A start worked out past either end is held so the run is inside the table.
  def test_a_start_off_the_table_is_held_inside_it
    { -3 => 0, 40 => LETTERS.length - 4 }.each do |start, held|
      assert_equal [LETTERS[held], LETTERS[held + 3], 4], on_console(copying(start: start)), "from #{start}"
    end
  end

  # WHAT IT IS FOR: a file screen letters three names of six 64-byte pictures from a table of
  # letter pictures, eighteen runs, on the frame it opens. Copied a byte at a time that was
  # most of a frame; as a block it is a small part of one.
  def test_eighteen_runs_of_64_bytes_take_a_small_part_of_a_frame
    rom = VBlank.build("LETTERS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprite :dot, at: [0, 0]
      pictures = table :pictures, (0...4096).map { |n| (n * 5) & 0x7F }, width: :byte
      pieces = Array.new(18) { |n| list :"piece#{n}", capacity: 64, width: :byte, fast: false }
      letter = var :letter, 0
      game_loop do
        letter.set! (letter + 1) & 63
        pieces.each { |piece| piece.copy_from pictures, at: letter * 64, count: 64 }
      end
    end
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)

    assert_operator result.idle_share, :>, 0.95, "eighteen copies left #{result.idle_share} of the frame"
  end
end
