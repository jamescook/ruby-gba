# frozen_string_literal: true

require "test_helper"

# The games these tests power on and how they read back where each record went, kept once for
# the console's table read back on the Advance's cartridge
# (test/lowering/gba/vblank/builder/test_save_places_on_the_advance_cartridge.rb).
module SavePlacesGames
  include SharedConstants

  Layout = VBlank::IR::SaveLayout
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
    builder = Builder.new(options: VBlank::Cartridge::Options.new(save_memory: save_memory))
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
end

# THE TESTS OF vblank/builder/test_save_places.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# WHERE EACH `save_data` RECORD GOES AT POWER-ON, asked one rule at a time.
#
# Each test starts a game from a table of places it wrote itself — the save memory an
# earlier build of the game would have left — powers it on, and reads back where every
# record ended up. The rules are the ones the console runs (see Builder::SavePlaces), run
# here on the interpreter; nothing else says them, so nothing here can drift from them.
class TestSavePlacesOnTheAdvance < Minitest::Test
  include SavePlacesGames

  # --- room nothing holds ---

  # --- a record the game no longer declares ---

  # --- a record this build changed ---

  # --- the last resort, when the free room is in pieces ---

  def test_records_slide_together_when_the_free_room_is_in_pieces
    third = ((ROOM / 3) / 4) * 4
    rows = [row(:left, START + third), row(:right, START + (2 * third))]
    big = { bytes: (third * 3 / 4) & ~3 } # half a copy of it is more than any one gap holds
    where = placed({ left: {}, right: {}, big: big }, rows)

    assert_equal({ left: [START, 1], right: [START + (2 * SMALL), 1], big: [START + (4 * SMALL), 1] }, where)
  end

  # The console running the same rules on the same save memory and ending with the same table,
  # read in the emulator, is in test/lowering/gba/vblank/builder/test_save_places_on_the_advance_cartridge.rb.

  # --- flash, which is wiped 4K at a time ---
  #
  # Where records go on flash is the same program on both backends, so the interpreter runs
  # it here. Flash keeps two 4K blocks for the two halves of the table, so save
  # data starts at 8K, and every half of a record takes whole blocks of its own.

  FLASH_START = 0x2000
  BLOCK = 0x1000

  def test_on_flash_a_new_record_goes_at_the_start_of_flash_save_data
    assert_equal({ file: [FLASH_START, 1] }, placed({ file: {} }, [], save_memory: 64))
  end

  # 64K is sixteen blocks and two are kept back, so three records of two copies — four
  # blocks each, however small a half is — and one of one copy fill it exactly, the last
  # ending at 64K. The build said they fit, and they do.
  def test_on_flash_records_take_whole_blocks_and_fill_the_memory_to_its_end
    records = { a: { copies: 2 }, b: { copies: 2 }, c: { copies: 2 }, d: {} }
    assert_equal({ a: [FLASH_START, 2], b: [FLASH_START + (4 * BLOCK), 2], c: [FLASH_START + (8 * BLOCK), 2],
                   d: [FLASH_START + (12 * BLOCK), 1] },
                 placed(records, [], save_memory: 64))
  end

  # Four blocks free at the start, two between, two at the end, and a record that needs six:
  # sliding the records down together leaves it its six in one piece, still on whole blocks.
  def test_on_flash_records_slide_together_on_whole_blocks
    rows = [row(:left, FLASH_START + (4 * BLOCK)), row(:right, FLASH_START + (8 * BLOCK))]
    big = { bytes: 9000 } # three blocks a half
    where = placed({ left: {}, right: {}, big: big }, rows, save_memory: 64)

    assert_equal({ left: [FLASH_START, 1], right: [FLASH_START + (2 * BLOCK), 1], big: [FLASH_START + (4 * BLOCK), 1] },
                 where)
  end

  # A save of the second copy goes in a half that starts on a block — the second copy's two
  # blocks are the third and fourth of the record's — and it loads back at the next power-on.
  def test_on_flash_a_save_lands_on_its_block_and_loads_back
    store = SaveImage.new
    game_player(save: store).input_each_frame { |f| f == 2 ? [:a] : [] }.run(flash_game, frames: 12)
    marked = [2, 3].map { |block| FLASH_START + (block * BLOCK) }.select { |at| store.word(at) == Layout::MARKER }

    assert_equal 1, marked.size, "one half of the second copy holds the save, at the start of a block"
    assert_equal 7, game_player(save: store).run(flash_game, frames: 2)[:hearts], "and it loads back"
  end

  # A record given a second copy, with a record right after it, moves to room further on — room
  # that still holds an old save of something else, which flash must wipe before the copy it
  # brings can be written there.
  def test_on_flash_a_record_moves_byte_for_byte_into_room_that_held_something_else
    rows = [row(:file, FLASH_START), row(:next, FLASH_START + (2 * BLOCK))]
    saved = (0...(2 * BLOCK)).to_h { |i| [FLASH_START + i, (i * 7) & 0xFF] }
    old = (0...(4 * BLOCK)).to_h { |i| [FLASH_START + (4 * BLOCK) + i, 0] }
    where = placed({ file: { copies: 2 }, next: {} }, rows, bytes: saved.merge(old), save_memory: 64)

    assert_equal({ file: [FLASH_START + (4 * BLOCK), 2], next: [FLASH_START + (2 * BLOCK), 1] }, where)
    moved = (0...(2 * BLOCK)).map { |i| @store.read(FLASH_START + (4 * BLOCK) + i, 1) }
    assert_equal saved.values, moved, "the copy it had came with it"
  end

  # The memory's free room is two blocks at the end, and a record grows by two: the ten
  # blocks above it lift by two, into blocks eight of which they are still in. Each block is
  # wiped only once what it held has been copied on.
  def test_on_flash_records_lifted_into_their_own_room_come_with_their_bytes
    above = { bytes: 18_000 } # five blocks a half, ten a copy
    rows = [row(:grower, FLASH_START), row(:above, FLASH_START + (2 * BLOCK), half: half(above))]
    saved = (0...(10 * BLOCK)).to_h { |i| [FLASH_START + (2 * BLOCK) + i, (i * 7) & 0xFF] }
    where = placed({ grower: { copies: 2 }, above: above }, rows, bytes: saved, save_memory: 64)

    assert_equal({ grower: [FLASH_START, 2], above: [FLASH_START + (4 * BLOCK), 1] }, where)
    moved = (0...(10 * BLOCK)).map { |i| @store.read(FLASH_START + (4 * BLOCK) + i, 1) }
    assert_equal saved.values, moved
  end

  # Each save goes into the older half, so the third lands where the first was — which flash
  # takes only once that half's blocks are wiped. An erase is a half written over too.
  def test_on_flash_a_copy_saved_over_and_over_loads_its_last_save
    store = SaveImage.new
    presses = { 2 => [:a], 6 => [:a], 10 => [:b], 14 => [:a] }
    game_player(save: store).input_each_frame { |f| presses.fetch(f, []) }.run(flash_game, frames: 30)

    assert_equal 9, game_player(save: store).run(flash_game, frames: 2)[:hearts]
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
  def test_the_records_above_are_lifted_when_one_grows_and_nothing_else_fits
    grower = { bytes: ((ROOM / 5) / 4) * 4, copies: 2 }
    size = half(grower) * 2 # one copy
    rows = [row(:grower, START, half: half(grower)), row(:above, START + size)]
    where = placed({ grower: grower, above: {} }, rows)

    assert_equal({ grower: [START, 2], above: [START + (2 * size), 1] }, where)
  end
end
