# frozen_string_literal: true

require "test_helper"

require "differential"

# The two-colour labels, shared with the Advance cartridge's own tests of them
# (test/lowering/gba/vblank/builder/test_text_two_colors_cartridge.rb).
module TextTwoColorsGames
  include SharedConstants

  X = 40
  Y = 30
  WORDS = "HI"

  # A long label, so the words are most of what is emitted and the comparison is plain.
  LONG = "I AM DEATH INCARNATE"

  # `flag` starts at 0 and is set to 1 once the A button is pressed, so one program
  # shows both colours depending on the input it is given.
  #
  # Where the draw goes differs by screen, and that is the ordinary tiled-text rule
  # rather than anything to do with two colours: a bitmap screen paints where you call
  # it, so the call goes in the loop; a tiled one declares its text once, above the loop,
  # and the console redraws it for you.
  private def label(on:, showing: nil)
    build_program do
      screen on
      flag = var :flag, 0
      pick = -> { showing ? showing.call(flag) : flag == 1 }
      if on == :bitmap
        game_loop do
          clear_screen :black
          pressed(:a).then { flag.set! 1 }
          draw_text WORDS, X, Y, %i[gray white], showing: pick.call
        end
      else
        draw_text WORDS, X, Y, %i[gray white], showing: pick.call
        game_loop { pressed(:a).then { flag.set! 1 } }
      end
    end
  end

  private def build_program(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # The button is read as HELD rather than pressed: the comparisons below hold it for the
  # whole run, and a button already down at power-on is a press on the console and not in
  # the interpreter's model of input, which would be a disagreement about input rather than
  # about the label.
  private def bitmap_label(words, tear_free:, colors:)
    build_program do
      screen :bitmap, tear_free: tear_free
      flag = var :flag, 0
      game_loop do
        clear_screen :black
        held(:a).then { flag.set! 1 }
        if colors.length == 1
          draw_text words, X, Y, colors.first
        else
          draw_text words, X, Y, colors, showing: flag == 1
        end
      end
    end
  end
end

# `draw_text words, x, y, [dull, bright], showing: test` — a label in one of two colours,
# with a test saying which.
#
# It says the same thing as the same words drawn twice, under a test and its opposite,
# and it paints the same pixels. What it saves is on a tiled screen, where the console
# draws each character as its own little sprite out of a table of 128: two draws are two
# sprites for every character with one of them always hidden, where this is one sprite
# that changes colour. So these tests check the PICTURE on both screens, and the sprite
# COUNT on the tiled one — the saving is the whole reason the form exists.
class TestTextTwoColors < Minitest::Test
  include Differential
  include TextTwoColorsGames

  Fonts = VBlank::Graphics::Fonts

  DULL = Color.resolve(:gray)
  BRIGHT = Color.resolve(:white)

  private def walk(program, frames:, press: false)
    interp = game_player
    interp = interp.input_each_frame { |f| press && f == 1 ? [:a] : [] }
    interp.run(program, frames: frames)
    interp
  end

  # The colour the words are drawn in, read off the picture.
  private def words_color(interp)
    lit = []
    Fonts.get(:default).each_pixel(WORDS) { |dx, dy| lit << [X + dx, Y + dy] }
    refute_empty lit
    colors = lit.map { |x, y| interp.screen.pixel(x, y) }.uniq

    assert_equal 1, colors.length, "the whole label should be one colour, got #{colors.inspect}"
    colors.first
  end

  private def sprites_in(program)
    program.walk.count { |node| node.kind == :object }
  end

  # ---- what it draws ----

  def test_a_bitmap_label_takes_the_first_colour_while_the_test_is_false
    assert_equal DULL, words_color(walk(label(on: :bitmap), frames: 3))
  end

  def test_a_bitmap_label_takes_the_second_colour_while_the_test_holds
    assert_equal BRIGHT, words_color(walk(label(on: :bitmap), frames: 3, press: true))
  end

  def test_a_tiled_label_takes_the_first_colour_while_the_test_is_false
    assert_equal DULL, words_color(walk(label(on: :tiled), frames: 3))
  end

  def test_a_tiled_label_takes_the_second_colour_while_the_test_holds
    assert_equal BRIGHT, words_color(walk(label(on: :tiled), frames: 3, press: true))
  end

  # ---- and what it costs, which is the point ----

  def test_a_tiled_label_is_one_sprite_per_character_however_many_colours_it_has
    one_color = build_program do
      screen :tiled
      draw_text WORDS, X, Y, :gray
      game_loop { }
    end

    assert_equal WORDS.length, sprites_in(label(on: :tiled)),
                 "a character is one sprite, and its two colours are two poses on it"
    assert_equal sprites_in(one_color), sprites_in(label(on: :tiled)),
                 "so a label that changes colour costs no more slots than one that does not"
  end

  def test_the_long_way_round_really_does_cost_twice_as_much
    written_out = build_program do
      screen :tiled
      flag = var :flag, 0
      (flag == 1).then { draw_text WORDS, X, Y, :white }
                 .else { draw_text WORDS, X, Y, :gray }
      game_loop { }
    end

    assert_equal 2 * WORDS.length, sprites_in(written_out),
                 "two draws are two sprites for every character, one of them always hidden"
  end

  # ---- the test it takes ----

  def test_a_plain_value_is_read_as_a_flag_rather_than_a_test
    dark = walk(label(on: :tiled, showing: ->(flag) { flag }), frames: 3)
    lit = walk(label(on: :tiled, showing: ->(flag) { flag }), frames: 3, press: true)

    assert_equal DULL, words_color(dark), "zero takes the first colour"
    assert_equal BRIGHT, words_color(lit), "anything else takes the second"
  end

  def test_a_composed_test_works_the_same_way
    program = build_program do
      screen :bitmap
      a = var :a, 1
      b = var :b, 1
      game_loop do
        clear_screen :black
        draw_text WORDS, X, Y, %i[gray white], showing: (a == 1) & (b == 1)
      end
    end

    assert_equal BRIGHT, words_color(walk(program, frames: 2))
  end

  # ---- friendly errors ----

  def test_two_colours_without_a_test_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program { screen :bitmap; game_loop { draw_text WORDS, X, Y, %i[gray white] } }
    end

    assert_match(/needs `showing:`/, error.message)
  end

  def test_one_colour_with_a_test_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flag = var :flag, 0
        game_loop { draw_text WORDS, X, Y, :gray, showing: flag == 1 }
      end
    end

    assert_match(/nothing to pick between/, error.message)
  end

  def test_three_colours_is_a_friendly_error_that_says_what_to_do_instead
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flag = var :flag, 0
        game_loop { draw_text WORDS, X, Y, %i[gray white red], showing: flag == 1 }
      end
    end

    assert_match(/picks between two colours, and got 3/, error.message)
    assert_match(/under a test for each/, error.message)
  end

  # ---- both backends, and the console ----

  def test_both_backends_draw_the_same_two_colour_label
    assert_backends_agree(label(on: :tiled), frames: 3)
  end

  # ---- a bitmap screen paints the words once, whichever colour they are ----
  #
  # What painting them once saves is measured in the cartridge's own tests
  # (test/lowering/gba/vblank/builder/test_text_two_colors_cartridge.rb). The console still
  # paints the colour the interpreter says, in both states, on both bitmap screens.
  def test_both_backends_agree_on_a_bitmap_label_in_its_first_colour
    assert_backends_agree(bitmap_label(LONG, tear_free: false, colors: %i[gray white]), frames: 3)
  end

  def test_both_backends_agree_on_a_bitmap_label_in_its_second_colour
    assert_backends_agree(bitmap_label(LONG, tear_free: false, colors: %i[gray white]), frames: 3, keys: [:a])
  end

  def test_both_backends_agree_on_a_tear_free_label_in_its_first_colour
    assert_backends_agree(bitmap_label(LONG, tear_free: true, colors: %i[gray white]), frames: 3)
  end

  def test_both_backends_agree_on_a_tear_free_label_in_its_second_colour
    assert_backends_agree(bitmap_label(LONG, tear_free: true, colors: %i[gray white]), frames: 3, keys: [:a])
  end
end
