# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_save_data"

# The power cut off part way through a save, which only the interpreter's save memory can do
# (SaveImage#cut_power_after counts the bytes written and drops the rest). The games are the ones
# test/all/vblank/builder/test_save_data.rb plays, and that a save comes back whole is there.
class TestSaveDataInterpreter < Minitest::Test
  include SaveDataGames

  # THE POWER GOING OFF IN THE MIDDLE OF A SAVE. The copy that was being written keeps its last
  # good save, and a copy that had none is damaged; the other copies are not touched.
  # RIGHT saves 99 over copy 0, which holds 10. The power goes off after each number of bytes
  # that save can write, in turn: at every one, copy 0 is either the old save or the new one —
  # never damaged, never a mixture — and copy 1 is untouched.
  def test_a_save_cut_off_at_any_point_keeps_the_last_good_one
    before = SaveImage.new
    files_after(before, :a, :up, :a)
    whole = before.dup
    game_player(save: whole).input_each_frame(&presses_from_first_pass(2 => :right)).run(three_files, frames: 4)
    assert_equal 99, files_after(whole)[:shown0], "uncut, the new save is the copy"

    (0..40).each do |cut|
      store = before.dup
      game_player(save: store.cut_power_after(cut))
               .input_each_frame(&presses_from_first_pass(2 => :right)).run(three_files, frames: 4)
      back = files_after(store)

      assert_equal [2, 2], [back[:state0], back[:state1]], "cut after #{cut} bytes"
      assert_includes [10, 99], back[:shown0], "cut after #{cut} bytes"
      assert_equal 11, back[:shown1], "cut after #{cut} bytes"
    end
  end

  # Cut after the header's first two words and four bytes of the body.
  def test_a_first_save_cut_off_half_way_is_damaged
    store = SaveImage.new
    files_after(store, :up, :up, :a)
    game_player(save: store.cut_power_after(12))
             .input_each_frame(&presses_from_first_pass(2 => :a)).run(three_files, frames: 4)
    back = files_after(store)

    assert_equal [3, 0, 2], (0..2).map { |n| back[:"state#{n}"] }
  end

  # THE POWER GOING OFF BETWEEN TWO PASSES OF A SAVE. A big save of 99 over a good save of 12
  # is cut after every so many bytes, across the passes it is written over: each time, the next
  # power-on finds the copy either as it was or as it was saved — never damaged, never a mix.
  def test_a_save_cut_off_between_passes_keeps_the_last_good_one
    before = SaveImage.new
    play(changes_while_saving, before, pressing: { 2 => :a }, frames: 20)
    resave = built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts, flags }
      files[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 99
          files[0].save
        end
      end
    end
    (0..1300).step(37) do |cut|
      store = before.dup
      game_player(save: store.cut_power_after(cut))
               .input_each_frame(&presses_from_first_pass(2 => :a)).run(resave, frames: 20)
      back = play(changes_while_saving, store, frames: 2)

      assert_includes [12, 99], back[:hearts], "cut after #{cut} bytes"
    end
  end

  # The power going off while the new build moves the files into their bigger place: at every
  # point, the next power-on still finds both files.
  def test_moving_a_record_cut_off_at_any_point_loses_nothing
    before = saved_by_the_first_build
    bigger = version(copies: 4)
    (0..400).step(3) do |cut|
      store = before.dup
      game_player(save: store.cut_power_after(cut)).run(bigger, frames: 2)
      back = play(bigger, store)

      assert_equal [42, 43, 7], [back[:shown0], back[:shown1], back[:kept_speed]], "cut after #{cut} bytes"
    end
  end

  # THE ORDER, read off a power cut at each step: the marker and the shape first, then the body,
  # then the sequence and the kind, and the checksum last of all — so until that last word is
  # in, the half cannot pass for good.
  def test_a_save_is_written_marker_first_and_checksum_last
    fresh = SaveImage.new
    play(header_and_body, fresh) # the table of places is written at the first power-on
    steps = { 8 => :opened, 8 + HEADER_AND_BODY_BODY => :body, 8 + HEADER_AND_BODY_BODY + 8 => :stamped }
    steps.each do |cut, step|
      store = fresh.dup
      game_player(save: store.cut_power_after(cut))
               .input_each_frame(&presses_from_first_pass(2 => :a)).run(header_and_body, frames: 12)
      half = half_with_marker(store, Layout::PACKED.data_start)
      body = store.read_bytes(half + Layout::HEADER, HEADER_AND_BODY_BODY)

      refute_equal 0, store.word(half + Layout::SHAPE_AT), "#{step}: the shape goes in with the marker"
      # A word not written yet is four bytes of 0xFF, which is what a fresh chip holds.
      assert_equal step == :opened ? [0xFF] * 4 : [7, 0, 0, 0], body[0, 4], "#{step}: the body"
      assert_equal step == :stamped ? 1 : -1, store.word(half + Layout::SEQUENCE_AT), "#{step}: the sequence"
      assert_equal(-1, store.word(half + Layout::CHECKSUM_AT), "#{step}: no checksum yet")
    end
  end
end
