# frozen_string_literal: true

require "test_helper"
require_relative "../examples/pong"

# Pong's title screen (examples/pong.rb): a two-row `menu` over the zooming backdrop.
#
# It is worth its own test file because of WHERE it runs. The title declares
# `screen :rotozoom`, so there is no framebuffer to paint into — the console composites
# every character of every row as a little sprite of its own. The menu written there is
# the same verb, written the same way, as the one the jukebox uses on a plain bitmap
# screen. These tests read the picture the console would show and never mention which of
# the two it is.
#
# The MUSIC row is the part that could not be written before: what it SAYS depends on the
# setting, so the row carries the list of things it can say and the variable that decides.
class TestPongTitle < Minitest::Test
  Fonts = RubyGBA::Fonts

  ROW_START = 90       # the menu's first row (examples/pong.rb: `at: [menu_x, 90]`)
  ROW_MUSIC = 106      # ...and the second, one `spacing: 16` below it
  CURSOR = ">"

  PICKED = Color.resolve(:white)
  PLAIN = Color.resolve(:gray)

  # Where the labels start. The example asks the font, so the test asks it the same way
  # rather than carrying a number that would go stale if a row were reworded.
  def column
    (240 - Fonts.get(:default).text_width(MUSIC_OFF)) / 2
  end

  def title(frames, &keys)
    i = Reference.new
    i = i.input_each_frame(&keys) if keys
    i.run(Pong.program, frames: frames)
    i
  end

  # Every lit pixel of +words+ laid on the font's grid from (x, y) — which is how the
  # console lays a row of glyph sprites out.
  def word_pixels(words, x, y)
    font = Fonts.get(:default)
    words.each_char.with_index.flat_map do |char, i|
      found = []
      font.each_pixel(char) { |dx, dy| found << [x + (i * font.cell_w) + dx, y + dy] }
      found
    end
  end

  # Is this row saying these words, in this colour?
  def says?(interp, words, y, color)
    pixels = word_pixels(words, column, y)
    refute_empty pixels, "#{words.inspect} should light some pixels"
    pixels.all? { |x, py| interp.screen.pixel(x, py) == color }
  end

  def cursor_row?(interp, y)
    word_pixels(CURSOR, column - 11, y).any? { |x, py| interp.screen.pixel(x, py).to_i.positive? }
  end

  # --- the menu is up, and says what it should ---

  def test_the_title_opens_on_the_start_row_with_the_music_on
    i = title(3) { |_f| [] }

    assert cursor_row?(i, ROW_START), "the cursor rests on START"
    assert says?(i, "START", ROW_START, PICKED), "and START is the picked row"
    assert says?(i, MUSIC_ON, ROW_MUSIC, PLAIN), "the music row says it is on, and is not picked"
    refute says?(i, MUSIC_OFF, ROW_MUSIC, PLAIN),
           "and says ONLY that — the other words are not sitting underneath it"
  end

  def test_moving_down_lights_the_music_row_instead
    i = title(4) { |f| f == 1 ? [:down] : [] }

    assert cursor_row?(i, ROW_MUSIC), "the cursor walked to the music row"
    assert says?(i, MUSIC_ON, ROW_MUSIC, PICKED), "which lights up, words and all"
    assert says?(i, "START", ROW_START, PLAIN), "and START goes plain again"
  end

  # --- the setting row, which is the point of it ---

  def test_choosing_the_music_row_changes_what_it_says
    i = title(6) { |f| { 1 => [:down], 3 => [:a] }.fetch(f, []) }

    assert says?(i, MUSIC_OFF, ROW_MUSIC, PICKED), "the row now reads MUSIC: OFF"
    refute says?(i, MUSIC_ON, ROW_MUSIC, PICKED), "and no longer reads MUSIC: ON"
  end

  def test_choosing_it_twice_puts_the_music_back_on
    i = title(9) { |f| { 1 => [:down], 3 => [:a], 6 => [:a] }.fetch(f, []) }

    assert says?(i, MUSIC_ON, ROW_MUSIC, PICKED)
    refute says?(i, MUSIC_OFF, ROW_MUSIC, PICKED), "and the words it used to say are gone"
  end

  def test_the_words_that_change_are_part_of_the_row_and_light_up_with_it
    off_and_picked = title(6) { |f| { 1 => [:down], 3 => [:a] }.fetch(f, []) }

    assert says?(off_and_picked, MUSIC_OFF, ROW_MUSIC, PICKED)

    # Walk back up to START: the same words are still there, now in the plain colour.
    off_and_plain = title(9) { |f| { 1 => [:down], 3 => [:a], 6 => [:up] }.fetch(f, []) }

    assert says?(off_and_plain, MUSIC_OFF, ROW_MUSIC, PLAIN),
           "the value the row shows is part of the row, so it dims with it"
  end

  # --- and it actually turns the music off ---

  def notes(interp)
    interp.audio.select { |entry| entry[0] == :note }
  end

  # Long enough to leave the title (START, then the zoom) and get well into a rally.
  INTO_THE_GAME = 200

  def test_the_music_plays_when_it_is_left_on
    i = title(INTO_THE_GAME) { |f| f < 3 ? [:a] : [] }

    refute_empty notes(i), "the gameplay song should be sounding"
  end

  def test_turning_the_music_off_on_the_title_keeps_it_off_in_the_game
    i = title(INTO_THE_GAME) do |f|
      # down to the music row, A to turn it off, up to START, A to begin.
      { 1 => [:down], 3 => [:a], 5 => [:up], 7 => [:a] }.fetch(f, [])
    end

    assert_empty notes(i), "nothing should sound for the whole rally"
  end

  # --- on the console ---

  def test_the_title_menu_composites_on_real_hardware
    require_gemba_core!
    rom = Pong.build_rom(out: StringIO.new, err: StringIO.new)

    still = assert_gemba_loads_rom(rom, frames: 6)

    assert still.white?(column - 11, ROW_START + 1),
           "the cursor sits beside START, drawn by the sprite hardware over the zooming backdrop"

    moved = assert_gemba_loads_rom(rom, frames: 8, keys: RubyGBA::Constants::KEY_DOWN)

    assert moved.white?(column - 11, ROW_MUSIC + 1), "and walks to the music row"
  end

  # The one column MUSIC: OFF reaches and MUSIC: ON does not — the last "F". A GLYPH
  # there while the music is on means both sets of words are on screen at once, printed
  # over each other, which is what a row showing every one of its labels looks like.
  #
  # "Is it black" is the wrong question of this screen: the title's backdrop is a
  # checkerboard, so that column is a dark tile rather than nothing. The question is
  # whether a LETTER is drawn on it, and a letter is one of the row's two colours.
  def beyond_the_shorter_words
    [column + (MUSIC_ON.length * Fonts.get(:default).cell_w), ROW_MUSIC]
  end

  def lettered?(verifier, at)
    verifier.pixel_is?(*at, :white) || verifier.pixel_is?(*at, :gray)
  end

  def test_the_console_shows_one_set_of_words_and_not_both
    require_gemba_core!
    rom = Pong.build_rom(out: StringIO.new, err: StringIO.new)

    on = assert_gemba_loads_rom(rom, frames: 6)

    refute lettered?(on, beyond_the_shorter_words),
           "MUSIC: ON is up, so no letter reaches the column only MUSIC: OFF fills"

    # Down onto the music row, then A to turn it off — and now that column IS lettered.
    walk = lambda do |frame|
      next RubyGBA::Constants::KEY_DOWN if frame < 3
      next 0 if frame < 6

      RubyGBA::Constants::KEY_A
    end
    off = assert_gemba_loads_rom(rom, frames: 12, keys: walk)

    assert lettered?(off, beyond_the_shorter_words), "and MUSIC: OFF reaches it"
  end
end
