# frozen_string_literal: true

require "test_helper"

# WHERE EACH `save_data` RECORD GOES AT POWER-ON, asked one rule at a time.
#
# Each test starts a game from a table of places it wrote itself — the save memory an
# earlier build of the game would have left — powers it on, and reads back where every
# record ended up. The rules are the ones the console runs (see Builder::SavePlaces), run
# here on the interpreter; nothing else says them, so nothing here can drift from them.
class TestSavePlaces < Minitest::Test
  Layout = RubyGBA::IR::SaveLayout
  Table = Layout::Table
  START = Layout::DATA_START
  ROOM = Layout::SIZE - Layout::DATA_START

  # A record that keeps one variable takes this much for one half of a copy.
  SMALL = Layout.half_bytes(4)

  # The game: each record keeps one variable, or, given +bytes+, a list that many bytes long.
  private def game(records)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      records.each do |name, spec|
        kept = spec[:bytes] ? list(:"#{name}_list", capacity: spec[:bytes], width: :byte) : var(:"#{name}_var", 0)
        save_data(name, copies: spec.fetch(:copies, 1)) { keep kept }
      end
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  # How big one half of +spec+'s record is.
  private def half(spec) = spec[:bytes] ? Layout.half_bytes(4 + spec[:bytes]) : SMALL

  private def row(name, at, half: SMALL, copies: 1)
    Table::Row.new(key: Layout.record_key(name), at: at, half: half, copies: copies)
  end

  # Power the game declaring +records+ on, with save memory holding +rows+ (and +bytes+), and
  # say where each record now is: name => [at, copies]. +names+ are the records to recognise
  # in the table, which includes ones the game no longer declares.
  private def placed(records, rows, bytes: {}, names: records.keys)
    store = { bytes: bytes.dup }
    Table.write(store[:bytes], rows)
    Reference.new(save: store).run(game(records), frames: 1)
    @store = store
    by_key = names.to_h { |name| [Layout.record_key(name), name] }
    Table.read(store[:bytes]).to_h { |one| [by_key.fetch(one.key), [one.at, one.copies]] }
  end

  # --- room nothing holds ---

  def test_a_new_record_goes_at_the_start_of_save_data
    assert_equal({ file: [START, 1] }, placed({ file: {} }, []))
  end

  def test_a_new_record_goes_after_the_records_in_the_way
    assert_equal({ file: [START, 1], extra: [START + (2 * SMALL), 1] },
                 placed({ file: {}, extra: {} }, [row(:file, START)]))
  end

  def test_a_new_record_fills_a_gap_it_fits
    rows = [row(:file, START), row(:last, START + (4 * SMALL))]
    assert_equal({ file: [START, 1], extra: [START + (2 * SMALL), 1], last: [START + (4 * SMALL), 1] },
                 placed({ file: {}, extra: {}, last: {} }, rows))
  end

  def test_a_gap_too_small_is_passed_over
    rows = [row(:file, START), row(:last, START + (3 * SMALL))]
    assert_equal({ file: [START, 1], extra: [START + (5 * SMALL), 1], last: [START + (3 * SMALL), 1] },
                 placed({ file: {}, extra: {}, last: {} }, rows))
  end

  # --- a record the game no longer declares ---

  def test_a_dropped_record_keeps_its_room_while_there_is_other_room
    assert_equal({ old: [START, 1], extra: [START + (2 * SMALL), 1] },
                 placed({ extra: {} }, [row(:old, START)], names: %i[old extra]))
  end

  def test_room_a_dropped_record_held_is_taken_back_when_nothing_else_fits
    everything = row(:old, START, half: ROOM / 2)
    assert_equal({ extra: [START, 1] }, placed({ extra: {} }, [everything], names: %i[old extra]))
  end

  # --- a record this build changed ---

  def test_a_record_that_keeps_other_things_is_given_new_room
    changed = row(:file, START + (6 * SMALL), half: SMALL + 4)
    assert_equal({ file: [START, 1] }, placed({ file: {} }, [changed]))
  end

  def test_a_record_with_fewer_copies_gives_back_the_room_after_them
    assert_equal({ file: [START, 1], extra: [START + (2 * SMALL), 1] },
                 placed({ file: {}, extra: {} }, [row(:file, START, copies: 3)]))
  end

  def test_a_record_with_more_copies_grows_where_it_is_when_the_room_after_is_free
    assert_equal({ file: [START, 2] }, placed({ file: { copies: 2 } }, [row(:file, START)]))
  end

  # Its copies move, byte for byte, to room big enough for all of them.
  def test_a_record_with_more_copies_moves_when_the_room_after_is_taken
    rows = [row(:file, START), row(:next, START + (2 * SMALL))]
    saved = (0...(2 * SMALL)).to_h { |i| [START + i, (i * 7) & 0xFF] }
    where = placed({ file: { copies: 2 }, next: {} }, rows, bytes: saved)

    assert_equal({ file: [START + (4 * SMALL), 2], next: [START + (2 * SMALL), 1] }, where)
    moved = (0...(2 * SMALL)).map { |i| @store[:bytes][START + (4 * SMALL) + i] }
    assert_equal saved.values, moved, "the copy it had came with it"
  end

  # --- the last resort, when the free room is in pieces ---

  def test_records_slide_together_when_the_free_room_is_in_pieces
    third = ((ROOM / 3) / 4) * 4
    rows = [row(:left, START + third), row(:right, START + (2 * third))]
    big = { bytes: (third * 3 / 4) & ~3 } # half a copy of it is more than any one gap holds
    where = placed({ left: {}, right: {}, big: big }, rows)

    assert_equal({ left: [START, 1], right: [START + (2 * SMALL), 1], big: [START + (4 * SMALL), 1] }, where)
  end

  # The console runs the same rules on the same save memory and ends with the same table.
  def test_the_console_slides_records_together_the_way_the_interpreter_does
    third = ((ROOM / 3) / 4) * 4
    records = { left: {}, right: {}, big: { bytes: (third * 3 / 4) & ~3 } }
    rows = [row(:left, START + third), row(:right, START + (2 * third))]
    oracle = placed(records, rows)
    rom = assemble_rom(game(records), name: "SLIDE")
    v = assert_emulator_loads_rom(rom, frames: 12, save: Table.write({}, rows))
    table = (0...(Layout::DATA_START - Layout::TABLE_AT)).to_h do |i| # both halves of the table
      [Layout::TABLE_AT + i, v.mem8(RubyGBA::Console::Hardware::SRAM_START + Layout::TABLE_AT + i)]
    end
    by_key = records.keys.to_h { |name| [Layout.record_key(name), name] }

    assert_equal oracle, Table.read(table).to_h { |one| [by_key.fetch(one.key), [one.at, one.copies]] }
  end

  def test_the_records_above_are_lifted_when_one_grows_and_nothing_else_fits
    grower = { bytes: ((ROOM / 5) / 4) * 4, copies: 2 }
    size = half(grower) * 2 # one copy
    rows = [row(:grower, START, half: half(grower)), row(:above, START + size)]
    where = placed({ grower: grower, above: {} }, rows)

    assert_equal({ grower: [START, 2], above: [START + (2 * size), 1] }, where)
  end
end
