# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "tmpdir"

# SAVING ON THE DESKTOP BUILD. The game as C keeps its save memory as the same bytes the
# interpreter's IR::SaveImage holds, which are the bytes the console's chip holds — so a save
# made by any of the three starts a game on any other. These are small made-up programs; the
# interpreter is the answer key for every one.
class TestNativeSaves < Minitest::Test
  include NativeComparison

  HeadlessRun = VBlank::IR::Backends::Native::HeadlessRun

  # A number kept in save memory, counted up two a frame from the 5 it is declared with.
  private def counting_up
    program_of do
      best = save_var :best, 5
      game_loop { best.add! 2 }
    end
  end

  def test_a_save_var_reads_the_same_on_every_frame
    last = assert_native_matches_reference counting_up, frames: 4

    assert_equal 13, last.variables[:best]
  end

  # TURNING IT OFF AND ON AGAIN is two runs handed the same save memory, as it is for the
  # interpreter: the second starts from what the first left there.
  def test_a_save_var_comes_back_after_the_power_goes_off
    store = SaveImage.new
    HeadlessRun.new(save: store).run(counting_up, frames: 3)

    again = HeadlessRun.new(save: store).run(counting_up, frames: 2)

    assert_equal 15, again[:best], "three frames took it to 11, and two more from there"
    assert_same store, again.save
  end

  def test_a_run_given_no_save_memory_starts_from_a_new_cartridge
    assert_equal 9, HeadlessRun.new.run(counting_up, frames: 2)[:best]
  end

  # The bytes are the ones the interpreter leaves, so a save can go from either to the other.
  def test_the_save_memory_a_run_leaves_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    natives = SaveImage.new
    HeadlessRun.new(save: natives).run(counting_up, frames: 3)

    assert_equal 11, natives.word(VBlank::IR::SaveLayout.save_var_at(0))
    assert_equal interpreters.to_sav, natives.to_sav
  end

  def test_a_save_the_interpreter_made_starts_the_game_as_c
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)

    assert_equal 13, HeadlessRun.new(save: store).run(counting_up, frames: 1)[:best]
  end

  # A game that never names save memory leaves the save memory it was handed alone.
  def test_a_game_that_saves_nothing_leaves_save_memory_as_it_was
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)
    before = store.to_sav
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    HeadlessRun.new(save: store).run(program, frames: 2)

    assert_equal before, store.to_sav
  end

  def test_save_memory_must_be_a_save_image_as_the_interpreter_says
    expected = assert_raises(ArgumentError) { Reference.new(save: {}) }

    error = assert_raises(ArgumentError) { HeadlessRun.new(save: {}) }

    assert_equal expected.message, error.message
  end

  # A chip cannot change size, so save memory of one size handed to a game with another is
  # refused, in the interpreter's words.
  def test_save_memory_of_another_size_is_refused_as_the_interpreter_refuses_it
    expected = assert_raises(SaveImage::WrongSize) { Reference.new(save: SaveImage.new(kilobytes: 64)).run(counting_up, frames: 1) }

    error = assert_raises(SaveImage::WrongSize) { HeadlessRun.new(save: SaveImage.new(kilobytes: 64)).run(counting_up, frames: 1) }

    assert_equal expected.message, error.message
  end

  # THE PROGRAM ITSELF keeps its save memory in a file it is told of (--save), which is how a
  # run is handed one: the bytes of a .sav file. With no file there it starts as a new cartridge,
  # and when it ends it leaves the file, written beside it first and then put in its place.
  def test_the_program_leaves_a_sav_file_where_there_was_none
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.sav")
      Native::Zig.run_program(Native.new.build_headless(counting_up), args: [3, "--save", path])

      assert_equal interpreters.to_sav, File.binread(path)
      assert_equal ["game.sav"], Dir.children(dir), "the file it was writing took the save file's place"
    end
  end

  # A file of another size is not this game's save memory, and is left as it is.
  def test_the_program_refuses_a_save_file_of_another_size
    Dir.mktmpdir do |dir|
      path = File.join(dir, "other.sav")
      File.binwrite(path, "\xFF".b * 100)

      error = assert_raises(Native::Zig::Error) do
        Native::Zig.run_program(Native.new.build_headless(counting_up), args: [3, "--save", path])
      end

      assert_match(/is not this game's save memory, which is 32768 bytes/, error.message)
      assert_equal 100, File.size(path)
    end
  end

  # --- save data ---
  #
  # From here every run is a CheckedPlayer: the game as C, then the same buttons on the
  # interpreter from the same save memory, failing at the first frame any variable differs — the
  # ones a save job keeps for itself among them — and at the end if the two chips do not hold the
  # same bytes. What each test asserts on top is that the run did what its name says.

  private def program_with(save_memory, &block)
    builder = Builder.new(options: VBlank::Cartridge::Options.new(save_memory: save_memory))
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # THREE SAVE FILES, picked by a number the game works out. Each button does one thing to the
  # file `slot` names: A saves the hearts and the name into it, B erases it, L loads it, R copies
  # file 0 over it, SELECT starts a new game, and UP moves the slot on. RIGHT saves 99 hearts.
  # What each file holds, and what state it is in, is read every frame without loading it.
  private def three_files(save_memory: nil)
    program_with(save_memory) do
      hearts = var :hearts, 3
      name = list :name, capacity: 3, width: :byte
      slot = var :slot, 0
      files = save_data(:file, copies: 3) { keep hearts, name }
      shown = Array.new(3) { |n| var :"shown#{n}", 0 }
      named = Array.new(3) { |n| var :"named#{n}", 0 }
      states = Array.new(3) { |n| var :"state#{n}", 0 }
      game_loop do
        pressed(:up).then { slot.add! 1 }
        pressed(:a).then do
          hearts.set! slot + 10
          name.push slot
          files[slot].save
        end
        pressed(:b).then { files[slot].erase }
        pressed(:l).then { files[slot].load }
        pressed(:r).then { files.copy 0, to: slot }
        pressed(:select).then { files.reset }
        pressed(:right).then do
          hearts.set! 99
          files[slot].save
        end
        3.times do |n|
          shown[n].set! files[n].peek(hearts)
          named[n].set! files[n].peek(name).length
          files[n].empty?.then { states[n].set! 0 }
          files[n].erased?.then { states[n].set! 1 }
          files[n].good?.then { states[n].set! 2 }
          files[n].damaged?.then { states[n].set! 3 }
        end
      end
    end
  end

  # Presses two frames apart, so each is a press of its own.
  private def presses(*buttons) = buttons.each_with_index.to_h { |button, i| [(i * 2) + 2, [button]] }

  private def files_after(store, *buttons, save_memory: nil)
    CheckedPlayer.new(save: store).input_each_frame { |frame| presses(*buttons).fetch(frame, []) }
                    .run(three_files(save_memory: save_memory), frames: (buttons.length * 2) + 4)
  end

  private def shown(run) = (0..2).map { |n| run[:"shown#{n}"] }
  private def states(run) = (0..2).map { |n| run[:"state#{n}"] }

  def test_each_copy_keeps_its_own_save_and_is_read_without_loading
    store = SaveImage.new
    files_after(store, :a, :up, :a, :up, :a)

    back = files_after(store)

    assert_equal [10, 11, 12], shown(back)
    assert_equal [1, 2, 3], (0..2).map { |n| back[:"named#{n}"] }, "each save kept the name as long as it then was"
    assert_equal [2, 2, 2], states(back)
    assert_equal 3, back[:hearts], "reading a copy does not load it"
  end

  def test_a_copy_loads_erases_and_is_copied_over_another
    store = SaveImage.new
    files_after(store, :a, :up, :a, :b, :up, :r)

    back = files_after(store, :up, :up, :l)

    assert_equal [10, 0, 10], shown(back)
    assert_equal [2, 1, 2], states(back), "good, erased, and a copy of the good one"
    assert_equal 10, back[:hearts], "copy 2 was loaded"
  end

  def test_a_new_game_puts_the_kept_things_back_and_leaves_the_files
    store = SaveImage.new

    run = files_after(store, :a, :select)

    assert_equal 3, run[:hearts]
    assert_equal [10, 0, 0], shown(run)
  end

  # THE POWER GOING OFF IN THE MIDDLE OF A SAVE. RIGHT saves 99 over copy 0, which holds 10. The
  # power goes off a number of bytes into that save, at the same byte in the C as in the
  # interpreter (the two are compared on the bytes the cut leaves), and copy 0 is the old save or
  # the new one, never a mixture.
  def test_a_save_cut_off_keeps_the_last_good_one
    before = SaveImage.new
    files_after(before, :a, :up, :a)

    found = [0, 1, 7, 19, 20, 24, 31, 40].map do |cut|
      store = before.dup
      files_after(store.cut_power_after(cut), :right)
      back = files_after(store)

      assert_equal [2, 2], states(back).first(2), "cut after #{cut} bytes"
      assert_equal 11, back[:shown1], "cut after #{cut} bytes"
      back[:shown0]
    end

    assert_equal [10, 99], found.uniq.sort, "the cuts reach from before the save to after it"
  end

  # A first save into a copy, cut after its header's first two words and four bytes of its body,
  # has no earlier one to fall back on, and reads as damaged. (Copy 2 is saved first, so the
  # table of places a new cartridge is given is written before the cut and not by it.)
  def test_a_first_save_cut_off_half_way_is_damaged
    store = SaveImage.new
    files_after(store, :up, :up, :a)

    files_after(store.cut_power_after(12), :a)

    assert_equal [3, 0, 2], states(files_after(store))
  end

  # EVERY SIZE OF SAVE MEMORY, each a different kind of chip with rules of its own: the EEPROM is
  # written a block of eight bytes at a time, the 32K takes any byte, and flash is wiped a block
  # before it is written. The save is the game's own routines, a piece each pass, so how many
  # passes it takes is part of what the two have to agree on.
  #
  # A saves 7 hearts and a list of sixty numbers; the game counts the passes a save was in hand
  # and the passes one finished on, and loads what is saved as it starts.
  private def slow_save(save_memory)
    program_with(save_memory) do
      hearts = var :hearts, 3
      trail = list :trail, capacity: 60
      busy = var :busy, 0
      done = var :done, 0
      failed = var :failed, 0
      file = save_data(:file) { keep hearts, trail }
      file[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 7
          repeat(60) { |i| trail.push i * 3 }
          file[0].save
        end
        file.saving?.then { busy.add! 1 }
        file.finished?.then { done.add! 1 }
        file.failed?.then { failed.add! 1 }
      end
    end
  end

  private def assert_saves_over_several_passes_and_comes_back(kilobytes, passes_at_least:)
    program = slow_save(kilobytes)
    store = SaveImage.new(kilobytes: kilobytes)

    saved = CheckedPlayer.new(save: store).input_each_frame { |frame| frame == 2 ? [:a] : [] }.run(program, frames: 150)
    back = CheckedPlayer.new(save: store).run(program, frames: 3)

    assert_equal [1, 0], [saved[:done], saved[:failed]], "the save finished once"
    assert_operator saved[:busy], :>=, passes_at_least, "the save was in hand over several passes"
    assert_equal 7, back[:hearts], "what was saved is loaded as the game starts"
  end

  def test_a_save_on_the_eeprom_takes_its_passes_and_comes_back
    assert_saves_over_several_passes_and_comes_back 8, passes_at_least: 20
  end

  def test_a_save_on_battery_memory_takes_its_passes_and_comes_back
    assert_saves_over_several_passes_and_comes_back 32, passes_at_least: 1
  end

  def test_a_save_on_64k_flash_takes_its_passes_and_comes_back
    assert_saves_over_several_passes_and_comes_back 64, passes_at_least: 5
  end

  def test_a_save_on_128k_flash_takes_its_passes_and_comes_back
    assert_saves_over_several_passes_and_comes_back 128, passes_at_least: 5
  end

  # ON FLASH A SAVE WIPES BEFORE IT WRITES, and a wipe takes long enough for the power to go off
  # in the middle of it: a cut of one step leaves half a block wiped. A saves 7 hearts, B saves
  # 9 and L saves 11. The save that is cut is the THIRD, so the half it wipes held a save of its
  # own — and one long enough to reach into the second half of its block, which is the part
  # half a wipe leaves as it was. Wherever the power goes off, the game comes back with the
  # second save or the third.
  def test_a_save_on_flash_cut_off_keeps_the_last_good_one
    program = program_with(64) do
      hearts = var :hearts, 3
      trail = list :trail, capacity: 2100, width: :byte
      repeat(2100) { trail.push 5 }
      file = save_data(:file) { keep hearts, trail }
      file[0].load
      game_loop do
        { a: 7, b: 9, l: 11 }.each do |button, amount|
          pressed(button).then do
            hearts.set! amount
            file[0].save
          end
        end
      end
    end
    before = SaveImage.new(kilobytes: 64)
    CheckedPlayer.new(save: before).input_each_frame { |frame| { 2 => [:a], 100 => [:b] }.fetch(frame, []) }
                    .run(program, frames: 200)

    found = [0, 1, 2, 3, 12, 5000].map do |cut|
      store = before.dup
      CheckedPlayer.new(save: store.cut_power_after(cut)).input_each_frame { |frame| frame == 2 ? [:l] : [] }
                      .run(program, frames: 100)

      CheckedPlayer.new(save: store).run(program, frames: 2)[:hearts].tap do |hearts|
        assert_includes [9, 11], hearts, "cut after #{cut} steps"
      end
    end

    assert_equal [9, 11], found.uniq.sort, "the cuts reach from before the save to after it"
  end

  # A game's `save_var`s on flash are kept in a record of their own, saved in the background
  # now and then rather than on the spot, and come back the same way.
  def test_save_vars_on_flash_come_back_after_the_power_goes_off
    program = program_with(64) do
      best = save_var :best, 5
      game_loop { pressed(:a).then { best.add! 2 } }
    end
    store = SaveImage.new(kilobytes: 64)
    CheckedPlayer.new(save: store).input_each_frame { |frame| frame == 2 ? [:a] : [] }.run(program, frames: 400)

    assert_equal 7, CheckedPlayer.new(save: store).run(program, frames: 2)[:best]
  end

  # THE OPTIMISED BUILD saves the same way. A CheckedPlayer plays the build with every check
  # on; this plays both builds from a new cartridge, on battery memory and on flash, and holds
  # each to the interpreter's variables on every frame.
  def test_both_builds_keep_save_data_as_the_interpreter_does
    last = assert_native_matches_reference three_files, frames: 20, buttons: presses(:a, :up, :a, :b, :up, :r, :l, :select)

    assert_equal [10, 0, 10], shown(last.variables)
    assert_equal [2, 1, 2], states(last.variables)
  end

  def test_both_builds_save_on_flash_as_the_interpreter_does
    last = assert_native_matches_reference slow_save(64), frames: 60, buttons: { 2 => [:a] }

    assert_equal 1, last.variables[:done]
  end

  # A SAVE WRITTEN STRAIGHT IN by a test (Reference.save_into, save_vars_into) is the bytes the
  # game itself would write, so the game as C starts from it like any other.
  def test_a_save_a_test_wrote_starts_the_game_as_c
    store = Reference.save_into(SaveImage.new, three_files, :file, 1, hearts: 42, name: [7, 8])

    back = files_after(store, :up, :l)

    assert_equal [0, 42, 0], shown(back)
    assert_equal [0, 2, 0], states(back)
    assert_equal 42, back[:hearts]
  end

  def test_a_save_var_a_test_wrote_starts_the_game_as_c
    store = Reference.save_vars_into(SaveImage.new, counting_up, best: 100)

    assert_equal 104, CheckedPlayer.new(save: store).run(counting_up, frames: 2)[:best]
  end
end
