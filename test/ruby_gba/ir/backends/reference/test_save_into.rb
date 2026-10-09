# frozen_string_literal: true

require "test_helper"

# A TEST WRITES A SAVE INTO SAVE MEMORY, so a game starts from a save it chose rather than
# being played until it saves one. The copy is the one the game itself would have written,
# so the game treats it the same as its own: good, read by peek and load, saved over, erased
# and copied like any other.
class TestSaveInto < Minitest::Test
  private def built(save_memory: nil, &block)
    save_memory ? RubyGBA.game("PUTSAVE", save_memory: save_memory, &block) : RubyGBA.game("PUTSAVE", &block)
  end

  private def files(save_memory: nil) = files_game(save_memory: save_memory).program

  # Two copies of a file keeping the hearts and a name, and a record of options keeping a
  # volume that holds a fraction. At power-on the game says whether copy 0 and copy 1 are good,
  # peeks at copy 1's hearts, and loads copy 0 and the options. A saves copy 0 with 7 hearts;
  # SELECT erases copy 1; START copies copy 0 over copy 1.
  private def files_game(save_memory: nil)
    built(save_memory: save_memory) do
      screen :bitmap
      hearts = var :hearts, 3
      name = list :name, capacity: 6, width: :byte
      volume = var :volume, 0.5
      first_good = var :first_good, 0
      second_good = var :second_good, 0
      second_hearts = var :second_hearts, 0
      file = save_data(:file, copies: 2) { keep hearts, name }
      options = save_data(:options) { keep volume }
      file[0].good?.then { first_good.set! 1 }
      file[1].good?.then { second_good.set! 1 }
      second_hearts.set! file[1].peek(hearts)
      file[0].load
      options[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 7
          file[0].save
        end
        pressed(:select).then { file[1].erase }
        pressed(:start).then { file.copy 0, to: 1 }
      end
    end
  end

  private def boot(program, image, pressing: {}, frames: 3)
    Reference.new(save: image).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  def test_a_written_copy_is_good_and_loads_back
    image = SaveImage.new
    Reference.save_into(image, files, :file, 0, hearts: 12, name: [76, 73, 78, 75])
    run = boot(files, image)

    assert_equal 1, run[:first_good]
    assert_equal 12, run[:hearts]
    assert_equal [76, 73, 78, 75], run.list(:name)
    assert_equal 0, run[:second_good], "the other copy was never written"
  end

  def test_peek_reads_a_written_copy
    image = SaveImage.new
    Reference.save_into(image, files, :file, 1, hearts: 5)
    run = boot(files, image)

    assert_equal 1, run[:second_good]
    assert_equal 5, run[:second_hearts]
  end

  # Kept things the test does not name take the values they were declared with.
  def test_what_the_test_leaves_out_is_as_declared
    image = SaveImage.new
    Reference.save_into(image, files, :file, 0, name: [65])
    run = boot(files, image)

    assert_equal 3, run[:hearts]
    assert_equal [65], run.list(:name)
  end

  # The game loads copy 0 at power-on, and copy 0 holds a name. A copy written after it, naming
  # only the hearts, still has the name it was declared with — nothing — rather than the one
  # the game loaded on the way in. L loads copy 1.
  def test_what_the_test_leaves_out_is_not_taken_from_another_copy
    program = built do
      screen :bitmap
      hearts = var :hearts, 3
      name = list :name, capacity: 6, width: :byte
      file = save_data(:file, copies: 2) { keep hearts, name }
      file[0].load
      game_loop { pressed(:l).then { file[1].load } }
    end.program
    image = SaveImage.new
    Reference.save_into(image, program, :file, 0, hearts: 12, name: [5, 6])
    Reference.save_into(image, program, :file, 1, hearts: 2)
    run = Reference.new(save: image).input_each_frame { |f| f == 2 ? [:l] : [] }.run(program, frames: 4)

    assert_equal [2, []], [run[:hearts], run.list(:name)]
  end

  def test_one_program_starts_in_two_states_from_two_images
    program = files
    low = SaveImage.new
    Reference.save_into(low, program, :file, 0, hearts: 1)
    high = SaveImage.new
    Reference.save_into(high, program, :file, 0, hearts: 20)

    assert_equal [1, 20], [boot(program, low)[:hearts], boot(program, high)[:hearts]]
  end

  # The game saves over a written copy, and that save counts as the newer one.
  def test_the_game_saves_over_a_written_copy
    program = files
    image = SaveImage.new
    Reference.save_into(image, program, :file, 0, hearts: 12)
    boot(program, image, pressing: { 2 => :a }, frames: 6)

    assert_equal 7, boot(program, image)[:hearts]
  end

  def test_the_game_erases_and_copies_a_written_copy
    program = files
    image = SaveImage.new
    Reference.save_into(image, program, :file, 0, hearts: 12)
    Reference.save_into(image, program, :file, 1, hearts: 4)
    boot(program, image, pressing: { 2 => :select }, frames: 6)
    assert_equal 0, boot(program, image)[:second_good], "erased"

    boot(program, image, pressing: { 2 => :start }, frames: 6)
    copied = boot(program, image)
    assert_equal [1, 12], [copied[:second_good], copied[:second_hearts]]
  end

  # Writing one copy leaves a copy the game saved, and the other records, as they were.
  def test_writing_one_copy_leaves_the_others_alone
    program = files
    image = SaveImage.new
    boot(program, image, pressing: { 2 => :a }, frames: 6) # the game saves copy 0 with 7 hearts
    Reference.save_into(image, program, :file, 1, hearts: 9)
    run = boot(program, image)

    assert_equal [7, 1, 9], [run[:hearts], run[:second_good], run[:second_hearts]]
  end

  # ...and another record's copy, written first, is still there after a file is written.
  def test_writing_a_copy_leaves_other_records_alone
    program = files
    image = SaveImage.new
    Reference.save_into(image, program, :options, 0, volume: 0.25)
    Reference.save_into(image, program, :file, 0, hearts: 9)
    run = boot(program, image)

    assert_equal [9, 0.25 * (1 << 16)], [run[:hearts], run[:volume]]
  end

  def test_flash_save_memory_takes_a_written_copy
    program = files(save_memory: 64)
    image = SaveImage.new
    Reference.save_into(image, program, :file, 0, hearts: 12, name: [1, 2])
    run = boot(program, image)

    assert_equal [1, 12, [1, 2]], [run[:first_good], run[:hearts], run.list(:name)]
  end

  # --- the console starts from a written copy too ---

  # The cartridge built from the same game, booted on each image: the copy is good, and the
  # game loads what was written. Nothing is rebuilt between the two.
  private def console_starts_from(save_memory: nil)
    game = files_game(save_memory: save_memory)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    [3, 15].map do |hearts|
      image = Reference.save_into(SaveImage.new, game.program, :file, 0, hearts: hearts, name: [1, 2, 3])
      Reference.save_into(image, game.program, :file, 1, hearts: hearts + 1)
      v = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)
      [v.var(:first_good), v.var(:hearts), v.var(:second_hearts)]
    end
  end

  # Copy 0 loaded, and copy 1 peeked at without loading it.
  def test_the_console_starts_from_a_written_copy
    assert_equal [[1, 3, 4], [1, 15, 16]], console_starts_from
  end

  def test_the_console_starts_from_a_written_copy_on_flash
    assert_equal [[1, 3, 4], [1, 15, 16]], console_starts_from(save_memory: 64)
  end

  # The random numbers a record keeps are written like a variable, and loaded back.
  def test_the_random_numbers_are_written_too
    program = built do
      screen :bitmap
      roll = var :roll, 0
      run = save_data(:run) { keep roll, random_numbers }
      run[0].load
      game_loop {}
    end.program
    image = Reference.save_into(SaveImage.new, program, :run, 0, roll: 2, random_numbers: 12_345)

    assert_equal 12_345, Reference.new(save: image).run(program, frames: 2)[RubyGBA::Builder::Randomness::RNG_STATE]
  end

  # --- what a test can get wrong ---

  def test_a_pool_is_refused_by_name
    program = built do
      screen :bitmap
      guards = pool :guard, x: 0, hp: 0, capacity: 4
      level = save_data(:level) { keep guards }
      level[0].load
      game_loop {}
    end.program
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, program, :level, 0, guard: [{ x: 1 }]) }
    assert_includes error.message, "the pool :guard"
    assert_includes error.message, "A test can write a variable"
  end

  # One field kept on its own is named by the field, and refused the same way.
  def test_a_pool_field_is_refused_by_its_name
    program = built do
      screen :bitmap
      guards = pool :guard, x: 0, hp: 0, capacity: 4
      level = save_data(:level) { keep guards.field(:hp) }
      level[0].load
      game_loop {}
    end.program
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, program, :level, 0, hp: [1, 2]) }
    assert_includes error.message, "the field :hp of the pool :guard"
  end

  def test_a_record_the_program_does_not_declare
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :progress, 0, hearts: 1) }
    assert_includes error.message, ":progress"
    assert_includes error.message, ":file"
  end

  def test_a_copy_the_record_does_not_have
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 2, hearts: 1) }
    assert_includes error.message, "There is no copy 2"
  end

  def test_a_fraction_and_a_whole_number_are_not_mixed_up
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, hearts: 3.5) }
    assert_includes error.message, "holds whole numbers"
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :options, 0, volume: 1) }
    assert_includes error.message, "holds a fraction"
  end

  def test_a_list_item_too_big_for_its_slot
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, name: [200]) }
    assert_includes error.message, "-128 to 127"
  end

  def test_a_name_the_record_does_not_keep
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, gold: 1) }
    assert_includes error.message, ":gold"
    assert_includes error.message, ":hearts"
    assert_includes error.message, ":name"
  end

  def test_a_value_of_the_wrong_kind
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, hearts: [1]) }
    assert_includes error.message, ":hearts"
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, name: 3) }
    assert_includes error.message, ":name"
  end

  def test_a_list_longer_than_its_capacity
    error = assert_raises(ArgumentError) { Reference.save_into(SaveImage.new, files, :file, 0, name: [1] * 7) }
    assert_includes error.message, "at most 6 items"
  end
end
