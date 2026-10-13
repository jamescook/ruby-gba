# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "pathname"
require "zlib"
require_relative "../../../examples/hero"

# A PLAYTHROUGH AND THE CARTRIDGE'S SAVE MEMORY: it can start holding a save, and it hands
# back the save memory as it left it — to write to a file, or to start the next playthrough
# from.
#
# The game is the hero example, which keeps three walks in three files. START saves the walk
# into the file that was picked, and the file screen shows how many steps each file holds
# without loading it — the game's variable `shown0` is the first file's.
class TestPlaythroughSaves < Minitest::Test
  private def hero = Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false)

  # FILE 1, NEW GAME, RIGHT held for +steps+ frames — a step a frame — and START to save.
  # The wait at the end is for the save to be written, which the game does a piece at a
  # time as it goes round its loop.
  private def walk_and_save(steps)
    RubyGBA.playthrough "hero: walk #{steps} steps and save" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      hold :right, frames: steps
      moment :walked
      press :start
      wait frames: 30
    end
  end

  # The file screen with nothing pressed, for long enough to have read its files.
  private def file_screen = RubyGBA.playthrough("hero: the file screen") { wait frames: 20 }

  private def steps_in_first_file(played) = played.game.var(:shown0)

  # A PLAYTHROUGH THAT SAVES HANDS BACK SAVE MEMORY, AND THE NEXT ONE STARTED FROM IT IS IN
  # THAT SAVE: the file screen shows the walk the first one saved.
  def test_a_save_handed_back_starts_the_next_playthrough_in_it
    cartridge = hero
    walked = walk_and_save(20).play(cartridge)

    assert_equal 20, walked.game.var(:steps), "twenty frames of RIGHT are twenty steps"
    assert_equal 0, steps_in_first_file(file_screen.play(cartridge)), "from power-on, the first file is empty"
    assert_equal 20, steps_in_first_file(file_screen.play(cartridge, save: walked.save)), "from the save, it holds the walk"
  end

  # THE SAVE CAN BE WRITTEN TO A FILE, AND A PLAYTHROUGH STARTED FROM THE FILE: by its path,
  # as text or as a Pathname.
  def test_a_save_file_on_disk_starts_a_playthrough_in_that_save
    cartridge = hero
    Dir.mktmpdir("saves") do |folder|
      path = walk_and_save(20).play(cartridge).save.write_sav(File.join(folder, "walk.sav"))

      assert_equal File.join(folder, "walk.sav"), path
      assert_equal 20, steps_in_first_file(file_screen.play(cartridge, save: path))
      assert_equal 20, steps_in_first_file(file_screen.play(cartridge, save: Pathname(path)))
    end
  end

  # THE SAVE A PLAYTHROUGH STARTS FROM IS LEFT AS IT WAS. The game goes on to save over it —
  # here it continues the walk of twenty, walks eight more and saves — and that is in the
  # save handed back, while the one handed in still holds twenty and can start another.
  def test_the_save_a_playthrough_starts_from_is_left_as_it_was
    cartridge = hero
    first = walk_and_save(20).play(cartridge).save
    second = walk_and_save(8).play(cartridge, save: first).save

    assert_equal 28, steps_in_first_file(file_screen.play(cartridge, save: second)), "continued, and saved again"
    assert_equal 20, steps_in_first_file(file_screen.play(cartridge, save: first)), "the save it started from is untouched"
  end

  # TWO PLAYTHROUGHS OF ONE CARTRIDGE AT THE SAME MOMENT EACH GET THEIR OWN SAVE BACK. Each
  # console keeps its save memory somewhere of its own, so these two, both running and both
  # saving, do not write into each other's.
  #
  # They are made to overlap: each stops when it has walked, before it saves, until the other
  # has walked too. Sharing one save memory, the second to save would write over the first
  # and both would hand back the same walk.
  def test_two_playthroughs_at_once_each_get_their_own_save_back
    cartridge = hero
    walked = Queue.new
    both_walked = Queue.new
    playing = [12, 20].map do |steps|
      Thread.new do
        walk_and_save(steps).play(cartridge) do |_moment, _game|
          walked << steps
          both_walked.pop
        end.save
      end
    end
    2.times { walked.pop }
    2.times { both_walked << :go }

    assert_equal([12, 20], playing.map(&:value).map { |save| steps_in_first_file(file_screen.play(cartridge, save: save)) })
  end

  # NO SAVE FILE IS LEFT BESIDE THE CARTRIDGE, which is where an emulator left to itself
  # writes one — and the next playing would then start in the last one's save. The cartridge
  # a console plays is a file the framework writes among the machine's temporary files, so
  # beside it is there: a playthrough that saves leaves no new save file among them.
  def test_a_playthrough_that_saves_leaves_no_save_file_beside_the_cartridge
    beside_a_cartridge = -> { Dir.glob(File.join(Dir.tmpdir, "*.sav")) }
    before = beside_a_cartridge.call
    played = walk_and_save(12).play(hero)

    refute_nil played.save, "the game did save"
    assert_empty beside_a_cartridge.call - before
  end

  # A cartridge with no save memory has none to hand back.
  def test_a_cartridge_with_no_save_memory_hands_back_no_save
    counting = RubyGBA.build("COUNTING", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_nil file_screen.play(counting).save
  end

  # --- what a tape says about where it started ---

  # A TAPE SAYS WHETHER IT WAS RECORDED FROM POWER-ON OR FROM A SAVE, and which save, for a
  # person to tell which tape belongs with which: a checksum of the save's bytes, as it says
  # one of the cartridge's. It keeps saying it through a file. The save itself is not in the
  # tape: a tape is the presses, and played on another cartridge it wants that one's own.
  def test_a_tape_says_whether_it_started_from_a_save_and_which
    cartridge = hero
    from_power_on = walk_and_save(20).play(cartridge)
    from_a_save = walk_and_save(8).play(cartridge, save: from_power_on.save).tape
    read_back = RubyGBA::Diagnostics::Playthrough::Tape.parse(from_a_save.to_s)

    assert_match(/^starts from: power-on$/, from_power_on.tape.to_s)
    assert_includes from_a_save.to_s.lines.map(&:chomp), format("starts from: a save 0x%08X", Zlib.crc32(from_power_on.save.to_sav))
    assert_equal from_a_save, read_back
  end

  # A TAPE RECORDED FROM A SAVE IS PLAYED FROM ONE. Played from power-on it would be the same
  # presses on a different game, which is never what was meant — so it is refused, before
  # anything is played, with how to hand the save over.
  def test_a_tape_recorded_from_a_save_is_refused_without_one
    cartridge = hero
    saved = walk_and_save(20).play(cartridge).save
    tape = walk_and_save(8).play(cartridge, save: saved).tape
    err = assert_raises(ArgumentError) { tape.play(nil) }

    assert_match(/from a save/, err.message)
    assert_match(/save:/, err.message)
    assert_equal 28, tape.play(cartridge, save: saved).game.var(:steps), "and with the save, it is the same walk"
  end

  # A comparison starts both cartridges from power-on, so a tape recorded from a save is not
  # one it can play.
  def test_a_tape_recorded_from_a_save_cannot_be_compared
    cartridge = hero
    saved = walk_and_save(20).play(cartridge).save
    tape = walk_and_save(8).play(cartridge, save: saved).tape
    err = assert_raises(ArgumentError) { tape.compare(nil, nil) }

    assert_match(/from a save/, err.message)
    assert_match(/power-on/, err.message)
  end

  # --- a save that cannot be one, each refused before anything is played ---

  # A save file is as big as the chip it is the memory of. A file of any other size is
  # something else given in its place — a tape, here — or the save of a chip this
  # framework's cartridges do not have. Either way it says how big the file is and how big
  # one can be.
  def test_a_file_that_is_not_the_size_of_any_save_memory_is_refused
    Dir.mktmpdir("saves") do |folder|
      path = walk_and_save(4).play(hero).tape.write(File.join(folder, "walk.tape"))
      err = assert_raises(ArgumentError) { file_screen.play(nil, save: path) }

      assert_match(/walk\.tape/, err.message)
      assert_match(/#{File.size(path)} bytes/, err.message)
      assert_match(/8K, 32K, 64K, 128K/, err.message)
    end
  end

  # The bytes of a save are not the path of one. Handed over by mistake they are named for
  # what they are, and not printed.
  def test_the_bytes_of_a_save_given_as_its_path_are_refused
    bytes = walk_and_save(4).play(hero).save.to_sav
    err = assert_raises(ArgumentError) { file_screen.play(nil, save: bytes) }

    assert_match(/#{bytes.bytesize} bytes/, err.message)
    assert_match(/from_sav/, err.message)
    assert_operator err.message.length, :<, 400
  end

  # A SAVE FROM A CARTRIDGE WITH ANOTHER SIZE OF SAVE MEMORY IS REFUSED, with both sizes,
  # before the console is switched on — and in the words of somebody who handed over a save,
  # not of somebody who made one by hand.
  def test_a_save_of_another_size_than_the_cartridges_is_refused
    too_big = RubyGBA::IR::SaveImage.new(kilobytes: 64)
    Dir.mktmpdir("saves") do |folder|
      [too_big, too_big.write_sav(File.join(folder, "other.sav"))].each do |wrong|
        err = assert_raises(ArgumentError) { file_screen.play(hero, save: wrong, pictures_in: File.join(folder, "pictures")) }

        assert_match(/64K/, err.message)
        assert_match(/32K/, err.message)
        refute_match(/SaveImage/, err.message)
      end
      refute File.exist?(File.join(folder, "pictures")), "refused before the folder for pictures was made"
    end
  end

  def test_a_save_file_that_is_not_there_is_refused
    err = assert_raises(ArgumentError) { file_screen.play(nil, save: "no/such/walk.sav") }

    assert_match(%r{no/such/walk\.sav}, err.message)
    assert_match(/no save file/, err.message)
  end

  def test_a_save_that_is_neither_a_save_nor_a_path_is_refused
    [42, :walk, true].each do |wrong|
      err = assert_raises(ArgumentError) { file_screen.play(nil, save: wrong) }

      assert_match(/save:/, err.message)
      assert_match(/path of a save file/, err.message)
    end
  end
end
