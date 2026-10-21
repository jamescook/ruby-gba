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
  START = Layout::PACKED.data_start
  ROOM = Layout::SIZE - Layout::PACKED.data_start

  # A record that keeps one variable takes this much for one half of a copy.
  SMALL = Layout.half_bytes(4)

  # The game: each record keeps one variable, or, given +bytes+, a list that many bytes long.
  private def game(records, save_memory: nil)
    built(save_memory: save_memory) do
      screen :tiled
      records.each do |name, spec|
        kept = spec[:bytes] ? list(:"#{name}_list", capacity: spec[:bytes], width: :byte) : var(:"#{name}_var", 0)
        save_data(name, copies: spec.fetch(:copies, 1)) { keep kept }
      end
      game_loop {}
    end
  end

  # The program the block declares, built with a Builder of its own rather than the way a game
  # is built, which refuses flash: the console cannot write it yet, and the interpreter can.
  private def built(save_memory:, &block)
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(save_memory: save_memory))
    builder.instance_eval(&block)
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
  # +save_memory+ is the cartridge's, in kilobytes; nil lets the records pick.
  private def placed(records, rows, bytes: {}, names: records.keys, save_memory: nil)
    store = SaveImage.new(kilobytes: save_memory || Layout::MEMORIES.first, bytes: bytes).write_table(rows)
    game_player(save: store).run(game(records, save_memory: save_memory), frames: 1)
    @store = store
    by_key = names.to_h { |name| [Layout.record_key(name), name] }
    store.table.to_h { |one| [by_key.fetch(one.key), [one.at, one.copies]] }
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
    moved = @store.read_bytes(START + (4 * SMALL), 2 * SMALL)
    assert_equal saved.values, moved, "the copy it had came with it"
  end

  # --- the last resort, when the free room is in pieces ---

  # --- flash, which is wiped 4K at a time ---
  #
  # Where records go on flash is the same program on both backends, so the interpreter runs
  # it here. Flash keeps two 4K blocks for the two halves of the table, so save
  # data starts at 8K, and every half of a record takes whole blocks of its own.

  FLASH_START = 0x2000
  BLOCK = 0x1000

  # One record more — two blocks, however small — is past what 64K holds, and the build says
  # so rather than placing it over the end. Records this small fit the packed 32K, where a
  # half takes only its own bytes, so that is the size the build says they need.
  def test_on_flash_one_record_more_than_fits_is_refused
    records = { a: { copies: 2 }, b: { copies: 2 }, c: { copies: 2 }, d: {}, e: {} }
    message = assert_raises(ArgumentError) { game(records, save_memory: 64) }.message

    assert_match(/save_memory: 64/, message)
    assert_match(/need 32K/, message)
  end

  # A 64K game keeping one number in two copies: A saves one more heart than last time (7 the
  # first time) into the second copy, B erases it, and power-on loads it.
  private def flash_game
    built(save_memory: 64) do
      screen :tiled
      hearts = var :hearts, 0
      files = save_data(:file, copies: 2) { keep hearts }
      files[1].load
      game_loop do
        pressed(:a).then do
          (hearts == 0).then { hearts.set! 6 }
          hearts.add! 1
          files[1].save
        end
        pressed(:b).then { files[1].erase }
      end
    end
  end


end
