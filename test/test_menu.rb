# frozen_string_literal: true

require "test_helper"

require_relative "differential"

# `menu` — a list of rows, a cursor that moves between them, and a block per row.
#
# These tests read the PICTURE, not the pick variable. Where the cursor sits is the
# thing a player can see, so a test that finds the cursor by looking for it would
# still catch a menu that moved its pick and drew somewhere else. The rows are given
# distinct colours for the same reason: "picked" is a colour on the screen, not a
# flag in memory.
class TestMenu < Minitest::Test
  include Differential

  X = 60           # where the labels start
  Y = 40           # the top of the first row
  SPACING = 20     # from one row's top to the next
  CURSOR_W = 11    # ">" plus a space, in the built-in font
  ROWS = ["ONE", "TWO", "THREE", "FOUR"].freeze

  PICKED = Color.resolve(:white)
  PLAIN = Color.resolve(:gray)
  DIMMED = Color.resolve(:red) # a colour of its own, so "dimmed" is visible in a test

  # A four-row menu whose second row cannot be picked. `chose` records which row's
  # block ran, so the action half is observable too. The same program is built for
  # either screen — that one verb reads the same way on both is the thing under test
  # in the tiled section below.
  def menu_program(press: :a, repeat_every: nil, on: :bitmap, &extra)
    build_program do
      screen on
      var :chose, 0
      game_loop do
        clear_screen :black if on == :bitmap
        options = { at: [X, Y], spacing: SPACING, color: :gray, picked: :white,
                    disabled: :red, press: press }
        options[:repeat_every] = repeat_every if repeat_every
        m = menu(:main, **options) do |rows|
          ROWS.each_with_index do |label, i|
            rows.item(label, enabled: i != 1) { set :chose, i + 1 }
          end
        end
        instance_exec(m, &extra) if extra
      end
    end
  end

  def build_program(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # Run a program, feeding it a fresh set of held buttons each frame.
  def walk(program, frames:, &keys)
    interp = Reference.new
    interp = interp.input_each_frame(&keys) if keys
    interp.run(program, frames: frames)
    interp
  end

  NOTHING_HELD = ->(_frame) { [] }

  # Which row the cursor is drawn beside, or nil if it is nowhere.
  def cursor_row(interp, column = X)
    ROWS.each_index.find { |row| lit?(interp, column - CURSOR_W, row) }
  end

  # The colour a row's label is drawn in, or nil if the row drew nothing.
  def row_color(interp, row)
    top = Y + (row * SPACING)
    (X...(X + 60)).each do |x|
      (0...7).each do |dy|
        px = interp.screen.pixel(x, top + dy)
        return px if px && px.positive?
      end
    end
    nil
  end

  def lit?(interp, x, row)
    top = Y + (row * SPACING)
    (x...(x + CURSOR_W)).any? do |px|
      (0...7).any? { |dy| interp.screen.pixel(px, top + dy).to_i.positive? }
    end
  end

  # ---- where the cursor starts, and what the rows look like ----

  def test_the_cursor_starts_on_the_first_row_that_can_be_picked
    i = walk(menu_program, frames: 2, &NOTHING_HELD)

    assert_equal 0, cursor_row(i)
    assert_equal PICKED, row_color(i, 0), "the picked row is drawn in its own colour"
    assert_equal PLAIN, row_color(i, 2), "a row the cursor is not on is drawn plainly"
  end

  def test_a_row_that_cannot_be_picked_is_drawn_in_its_own_colour
    i = walk(menu_program, frames: 2, &NOTHING_HELD)

    assert_equal DIMMED, row_color(i, 1)
  end

  # ---- moving ----

  def test_down_moves_the_cursor_and_up_moves_it_back
    down = walk(menu_program, frames: 3) { |f| f == 1 ? [:down] : [] }

    assert_equal 2, cursor_row(down), "row 1 cannot be picked, so down lands on row 2"

    back = walk(menu_program, frames: 6) { |f| { 1 => [:down], 4 => [:up] }.fetch(f, []) }

    assert_equal 0, cursor_row(back), "up from row 2 steps back over row 1"
  end

  def test_the_cursor_wraps_at_both_ends
    # A tap every third frame, so each one is a fresh press rather than a repeat.
    off_the_bottom = walk(menu_program, frames: 9) { |f| f % 3 == 1 ? [:down] : [] }

    assert_equal 0, cursor_row(off_the_bottom),
                 "three moves from row 0 walk to 2, then 3, then round to 0"

    off_the_top = walk(menu_program, frames: 3) { |f| f == 1 ? [:up] : [] }

    assert_equal 3, cursor_row(off_the_top), "up from the first row lands on the last"
  end

  def test_a_row_that_cannot_be_picked_is_never_landed_on
    seen = (1..12).map do |frames|
      cursor_row(walk(menu_program, frames: frames) { |f| f % 3 == 1 ? [:down] : [] })
    end

    assert_empty seen.select(&:nil?), "the cursor is on the screen at every step of the walk"
    refute_includes seen, 1, "the cursor never rests on the row that cannot be picked"
  end

  # ---- held-button repeat ----

  # Counting the moves rather than reading the row the walk ended on: a menu that
  # raced down the list one row a frame can land on the right row by coincidence, and
  # in a three-row walk it often does.
  def counting_moves(repeat_every:)
    menu_program(repeat_every: repeat_every) { |m| m.moved.then { add :chose, 1 } }
  end

  def test_holding_a_button_walks_the_list_instead_of_racing_down_it
    i = walk(counting_moves(repeat_every: 20), frames: 25) { |_f| [:down] }

    assert_equal 2, i[:chose], "in 25 frames a 20-frame repeat steps twice, not 25 times"
    assert_equal 3, cursor_row(i), "0 to 2 over the row that cannot be picked, then 2 to 3"
  end

  def test_a_tap_moves_exactly_one_row_however_long_the_button_is_down
    i = walk(counting_moves(repeat_every: 60), frames: 30) { |_f| [:down] }

    assert_equal 1, i[:chose], "one move, and the wait swallows the other 29 frames"
    assert_equal 2, cursor_row(i)
  end

  def test_letting_go_clears_the_wait_so_the_next_tap_moves_at_once
    i = walk(counting_moves(repeat_every: 60), frames: 6) { |f| f.odd? ? [:down] : [] }

    assert_equal 3, i[:chose],
                 "three taps inside one repeat window are three moves, not one"
    assert_equal 0, cursor_row(i), "and three moves walk back round to the first row"
  end

  # ---- choosing ----

  def test_the_press_button_runs_the_picked_rows_block
    i = walk(menu_program, frames: 3) { |f| f == 1 ? [:a] : [] }

    assert_equal 1, i[:chose], "row 0's block ran"
  end

  def test_choosing_runs_the_block_of_whichever_row_the_cursor_reached
    i = walk(menu_program, frames: 6) { |f| { 1 => [:down], 4 => [:a] }.fetch(f, []) }

    assert_equal 3, i[:chose], "the cursor was on row 2, so row 2's block ran"
  end

  def test_holding_the_button_chooses_once_not_once_a_frame
    i = build_program do
      screen :bitmap
      var :times, 0
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y]) { |rows| rows.item("GO") { add :times, 1 } }
      end
    end
    held = walk(i, frames: 10) { |_f| [:a] }

    assert_equal 1, held[:times], "a held button is one press"
  end

  def test_a_menu_can_be_read_and_moved_by_the_game
    program = menu_program { |m| (m.picked == 2).then { set :chose, 99 } }
    i = walk(program, frames: 3) { |f| f == 1 ? [:down] : [] }

    assert_equal 99, i[:chose], "the game read which row the cursor is on"
  end

  def test_moved_is_true_only_on_the_frame_the_cursor_changed_rows
    program = menu_program { |m| m.moved.then { add :chose, 1 } }
    i = walk(program, frames: 10) { |f| f == 1 ? [:down] : [] }

    assert_equal 1, i[:chose], "one move in ten frames is one `moved`"
  end

  # ---- the pick is remembered ----

  def test_the_pick_survives_leaving_the_scene_and_coming_back
    program = build_program do
      screen :bitmap
      state = var :state, 0
      game_loop do
        clear_screen :black
        case_var(:state) do
          when_val 0, :picking
          when_val 1, :away
        end
      end
      scene :picking do
        menu(:main, at: [X, Y], spacing: SPACING) do |rows|
          ROWS.each { |label| rows.item(label) }
        end
        pressed(:b).then { state.set 1 }
      end
      scene :away do
        draw_text "AWAY", 10, 120, :white
        pressed(:b).then { state.set 0 }
      end
    end

    # Move down twice, leave, come back — and the cursor is where it was left.
    i = walk(program, frames: 12) { |f| { 1 => [:down], 3 => [:down], 5 => [:b], 8 => [:b] }.fetch(f, []) }

    assert_equal 2, cursor_row(i)
  end

  def test_two_menus_keep_their_own_pick
    program = build_program do
      screen :bitmap
      game_loop do
        clear_screen :black
        menu(:left, at: [X, Y], spacing: SPACING) { |r| ROWS.each { |l| r.item(l) } }
        right = menu(:right, at: [160, Y], spacing: SPACING) { |r| ROWS.each { |l| r.item(l) } }
        # Setting the pick jumps that cursor, and only that one.
        right.picked.set 3
      end
    end
    i = walk(program, frames: 2, &NOTHING_HELD)

    assert_equal 0, cursor_row(i, X), "the left menu is where it started"
    assert_equal 3, cursor_row(i, 160), "the right menu was moved on its own"
  end

  # ---- decoration a game says rather than builds ----

  def test_a_row_can_carry_its_own_colours
    program = build_program do
      screen :bitmap
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, color: :gray, picked: :white) do |rows|
          rows.item("ONE", picked: :yellow)
          rows.item("TWO", color: :cyan)
        end
      end
    end
    i = walk(program, frames: 2, &NOTHING_HELD)

    assert_equal Color.resolve(:yellow), row_color(i, 0), "the picked row uses its own colour"
    assert_equal Color.resolve(:cyan), row_color(i, 1), "an unpicked row uses its own colour"
  end

  # ---- a row whose words change ----

  # A settings row says a different thing depending on the setting, so it carries the
  # list of things it can say and the variable that decides. The words are part of the
  # row: they light up with it and dim with it.
  def settings_menu(&extra)
    build_program do
      screen :bitmap
      music = var :music, 1
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, color: :gray, picked: :white) do |rows|
          rows.item(["MUSIC OFF", "MUSIC ON"], showing: music) { music.set 1 - music }
          rows.item("START")
        end
        instance_exec(music, &extra) if extra
      end
    end
  end

  # The two labels differ in length, so how far the row reaches says which one is up.
  def row_extent(interp, row)
    top = Y + (row * SPACING)
    lit = (0...240).select { |x| (0...7).any? { |dy| interp.screen.pixel(x, top + dy).to_i.positive? } }
    lit.empty? ? nil : lit.last
  end

  def test_a_row_shows_the_words_its_value_points_at
    on = walk(settings_menu, frames: 2, &NOTHING_HELD)
    off = walk(settings_menu, frames: 4) { |f| f == 1 ? [:a] : [] }

    assert_operator row_extent(off, 0), :>, row_extent(on, 0),
                    "MUSIC OFF is a character longer than MUSIC ON, so the row reaches further"
    assert_equal PICKED, row_color(off, 0), "and the words that changed are still the picked row"
  end

  def test_the_row_shows_one_set_of_words_and_not_the_other
    i = walk(settings_menu, frames: 2, &NOTHING_HELD)
    reach_of_the_longer = row_extent(walk(settings_menu, frames: 4) { |f| f == 1 ? [:a] : [] }, 0)

    (row_extent(i, 0) + 1..reach_of_the_longer).each do |x|
      (0...7).each do |dy|
        assert_equal 0, interp_pixel(i, x, Y + dy),
                     "nothing of the other words is drawn underneath at (#{x},#{Y + dy})"
      end
    end
  end

  def interp_pixel(interp, x, y)
    interp.screen.pixel(x, y).to_i
  end

  def test_a_showing_value_can_be_named_as_a_symbol
    program = build_program do
      screen :bitmap
      var :music, 0
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y]) { |r| r.item(%w[OFF ON], showing: :music) }
      end
    end
    i = walk(program, frames: 2, &NOTHING_HELD)

    assert_equal PICKED, row_color(i, 0), "the row drew, reading the variable by name"
  end

  def test_a_row_that_can_say_several_things_needs_showing
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        game_loop { menu(:main, at: [X, Y]) { |r| r.item(%w[OFF ON]) } }
      end
    end

    assert_match(/needs `showing:`/, error.message)
  end

  def test_a_row_that_says_one_thing_does_not_take_showing
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        music = var :music, 0
        game_loop { menu(:main, at: [X, Y]) { |r| r.item("MUSIC", showing: music) } }
      end
    end

    assert_match(/does not need `showing:`/, error.message)
  end

  def test_a_row_whose_words_are_not_strings_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        music = var :music, 0
        game_loop { menu(:main, at: [X, Y]) { |r| r.item([1, 2], showing: music) } }
      end
    end

    assert_match(/two or more Strings/, error.message)
  end

  def test_a_showing_that_is_not_a_variable_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        game_loop { menu(:main, at: [X, Y]) { |r| r.item(%w[OFF ON], showing: 3) } }
      end
    end

    assert_match(/takes the variable/, error.message)
  end

  def test_a_menu_can_be_drawn_with_no_cursor_at_all
    program = build_program do
      screen :bitmap
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, cursor: "") { |r| ROWS.each { |l| r.item(l) } }
      end
    end
    i = walk(program, frames: 2, &NOTHING_HELD)

    assert_nil cursor_row(i), "nothing is drawn to the left of the labels"
    assert_equal PICKED, row_color(i, 0), "the colour still says which row is picked"
  end

  # ---- friendly errors ----

  def test_a_menu_with_no_rows_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program { screen :bitmap; game_loop { menu(:main, at: [0, 0]) { |_r| } } }
    end

    assert_match(/no rows/, error.message)
  end

  def test_a_menu_where_nothing_can_be_picked_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        game_loop { menu(:main, at: [0, 0]) { |r| r.item("ONE", enabled: false) } }
      end
    end

    assert_match(/nowhere/, error.message)
  end

  def test_a_menu_with_no_block_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program { screen :bitmap; game_loop { menu(:main, at: [0, 0]) } }
    end

    assert_match(/needs its rows/, error.message)
  end

  def test_a_menu_above_the_game_loop_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        menu(:main, at: [0, 0]) { |r| r.item("ONE") }
        game_loop { clear_screen :black }
      end
    end

    assert_match(/inside your game_loop/, error.message)
  end

  def test_a_row_that_does_not_say_anything_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program { screen :bitmap; game_loop { menu(:main, at: [0, 0]) { |r| r.item(42) } } }
    end

    assert_match(/a String/, error.message)
  end

  def test_a_place_that_is_not_a_pair_of_numbers_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program { screen :bitmap; game_loop { menu(:main, at: 40) { |r| r.item("ONE") } } }
    end

    assert_match(/text_width/, error.message)
  end

  def test_an_unknown_button_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        game_loop { menu(:main, at: [0, 0], press: :fire) { |r| r.item("ONE") } }
      end
    end

    assert_match(/not a known button/, error.message)
  end

  # ---- on a tiled screen ----
  #
  # There is no framebuffer there: the console composites the picture, and every
  # character of every row is one little 8x8 sprite it draws for you. So the same menu
  # is built out of something completely different — and the point of these tests is
  # that a game cannot tell, because they are the bitmap tests again with one word
  # changed.

  def tiled_menu(**options, &extra)
    menu_program(on: :tiled, **options, &extra)
  end

  def test_a_tiled_menu_draws_its_rows_in_the_same_three_colours
    i = walk(tiled_menu, frames: 3, &NOTHING_HELD)

    assert_equal 0, cursor_row(i)
    assert_equal PICKED, row_color(i, 0), "the picked row"
    assert_equal DIMMED, row_color(i, 1), "the row that cannot be picked"
    assert_equal PLAIN, row_color(i, 2), "a row the cursor is not on"
  end

  def test_a_tiled_menu_moves_wraps_and_steps_over_what_cannot_be_picked
    down = walk(tiled_menu, frames: 3) { |f| f == 1 ? [:down] : [] }

    assert_equal 2, cursor_row(down), "down steps over the row that cannot be picked"
    assert_equal PICKED, row_color(down, 2), "and the row it landed on lights up"
    assert_equal PLAIN, row_color(down, 0), "and the one it left goes plain again"

    up = walk(tiled_menu, frames: 3) { |f| f == 1 ? [:up] : [] }

    assert_equal 3, cursor_row(up), "up from the first row wraps to the last"
  end

  def test_a_tiled_menu_runs_the_picked_rows_block
    i = walk(tiled_menu, frames: 6) { |f| { 1 => [:down], 4 => [:a] }.fetch(f, []) }

    assert_equal 3, i[:chose]
  end

  def test_a_tiled_menu_holds_its_repeat_the_same_way
    program = tiled_menu(repeat_every: 60) { |m| m.moved.then { add :chose, 1 } }
    i = walk(program, frames: 30) { |_f| [:down] }

    assert_equal 1, i[:chose], "one move, and the wait swallows the other 29 frames"
  end

  # A scene owns what it draws, and on a tiled screen that is the console's own gate
  # rather than something the menu re-checks. So a menu in a scene is on screen while
  # that scene is, and gone while it is not — with nothing said about it here.
  def test_a_tiled_menu_in_a_scene_shows_only_while_that_scene_is_active
    program = build_program do
      screen :tiled
      state = var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :picking
          when_val 1, :away
        end
      end
      scene :picking do
        menu(:main, at: [X, Y], spacing: SPACING, color: :gray, picked: :white) do |rows|
          ROWS.each { |label| rows.item(label) }
        end
        pressed(:b).then { state.set 1 }
      end
      scene :away do
        pressed(:b).then { state.set 0 }
      end
    end

    showing = walk(program, frames: 3, &NOTHING_HELD)

    assert_equal PICKED, row_color(showing, 0), "the menu is up while its scene runs"

    gone = walk(program, frames: 6) { |f| f == 1 ? [:b] : [] }

    assert_nil row_color(gone, 0), "and nothing of it is left once the scene changes"
    assert_nil cursor_row(gone), "the cursor goes with it"
  end

  def test_a_tiled_menu_above_the_game_loop_is_still_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_program do
        screen :tiled
        menu(:main, at: [X, Y]) { |r| ROWS.each { |l| r.item(l) } }
        game_loop { }
      end
    end

    assert_match(/inside your game_loop/, error.message)
  end

  # A long menu, for counting sprites with. 12 rows of 12 characters is past the
  # console's 128; 8 rows of 10 is not.
  def long_menu(rows_of:, on: :tiled)
    build_program do
      screen on
      game_loop do
        clear_screen :black if on == :bitmap
        menu(:main, at: [0, 0], spacing: 8) do |rows|
          rows_of.times { |i| rows.item("LONGOPTION#{i}") }
        end
      end
    end
  end

  def sprites_in(program)
    program.walk.count { |node| node.kind == :object }
  end

  # A row lights up by changing colour, not by being drawn twice — so it costs one
  # sprite per character and not two. That is the difference between an eight-row menu
  # fitting and not fitting, so it is worth pinning as a number.
  def test_a_tiled_row_costs_one_sprite_per_character_not_two
    program = long_menu(rows_of: 8)
    characters = 8 * "LONGOPTION0".length
    cursors = 8

    assert_equal characters + cursors, sprites_in(program),
                 "one sprite for each character, plus a cursor for each row"
  end

  # The console draws 128 sprites at once, so a long enough menu runs out. That is the
  # one place the two screens really differ, so it gets a friendly error naming the
  # count rather than a bare failure from the lowering with anonymous sprites in it.
  def test_a_tiled_menu_too_big_for_the_sprite_table_is_a_friendly_error
    error = assert_raises(ArgumentError) { long_menu(rows_of: 12) }

    assert_match(/at most 128 at once/, error.message)
    assert_match(/screen :bitmap/, error.message)
  end

  def test_the_same_menu_costs_no_sprites_at_all_on_a_bitmap_screen
    assert_equal 0, sprites_in(long_menu(rows_of: 12, on: :bitmap)),
                 "a bitmap screen paints the rows into the picture"
  end

  # A tiled menu is made of the things the console redraws for you, so it takes a place
  # in the stack like anything else the console redraws. Nothing in the menu knows about
  # layers — the rows are `draw_text`, and tiled text is layerable.
  def test_a_tiled_menu_takes_a_place_in_the_stack
    program = build_program do
      screen :tiled
      layers :world, :ui
      game_loop do
        layer(:ui) do
          menu(:main, at: [X, Y], spacing: SPACING) { |r| ROWS.each { |l| r.item(l) } }
        end
      end
    end
    rows = program.walk.select { |node| node.kind == :object }

    refute_empty rows
    assert_equal [:ui], rows.map(&:layer).uniq, "every glyph of the menu is in :ui"
  end

  # ...and on a bitmap screen it cannot, because a bitmap menu paints where it is called
  # and no ordering applied later can reach back and move those pixels. The message has
  # to say `menu`, which is what the author wrote, not the draw_text underneath it.
  def test_a_bitmap_menu_in_a_layer_is_a_friendly_error_that_names_menu
    error = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        layers :world, :ui
        game_loop { layer(:ui) { menu(:main, at: [X, Y]) { |r| r.item("ONE") } } }
      end
    end

    assert_match(/`menu` paints where you call it/, error.message)
    refute_match(/draw_text/, error.message)
  end

  def test_both_backends_draw_the_same_tiled_menu
    assert_backends_agree(tiled_menu, frames: 3)
  end

  def test_a_tiled_menu_moves_on_real_hardware
    require_emulator!
    rom = RubyGBA.build("TMENU", code: "BTMN", maker: "01", validate: false) do
      screen :tiled
      game_loop do
        menu(:main, at: [X, Y], spacing: SPACING, picked: :white, color: :gray) do |rows|
          ROWS.each_with_index { |label, i| rows.item(label, enabled: i != 1) }
        end
      end
    end

    cursor_pixel = ->(row) { [X - CURSOR_W, Y + (row * SPACING) + 1] }

    still = assert_emulator_loads_rom(rom, frames: 4)

    assert still.white?(*cursor_pixel.call(0)), "the cursor rests beside the first row"

    moved = assert_emulator_loads_rom(rom, frames: 6, keys: RubyGBA::Constants::KEY_DOWN)

    assert moved.white?(*cursor_pixel.call(2)),
           "the console composites the cursor onto the row it walked to"
  end

  # ---- the guardrail ----

  def warnings(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_menu_with_no_game_loop_is_caught
    program = build_program do
      screen :bitmap
      func(:draw_it) { menu(:main, at: [X, Y]) { |r| ROWS.each { |l| r.item(l) } } }
      call :draw_it
      halt
    end

    assert_includes warnings(program), :menu_needs_game_loop
  end

  def test_a_menu_inside_a_game_loop_is_not_flagged
    refute_includes warnings(menu_program), :menu_needs_game_loop
  end

  # ---- on the console ----

  def test_the_cursor_moves_on_real_hardware
    require_emulator!
    rom = RubyGBA.build("MENU", code: "BMNU", maker: "01", validate: false) do
      screen :bitmap
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, picked: :white, color: :gray) do |rows|
          ROWS.each_with_index { |label, i| rows.item(label, enabled: i != 1) }
        end
      end
    end

    # The cursor's ">" is a chevron: its second row is one pixel at the left edge.
    cursor_pixel = ->(row) { [X - CURSOR_W, Y + (row * SPACING) + 1] }

    still = assert_emulator_loads_rom(rom, frames: 4)

    assert still.white?(*cursor_pixel.call(0)), "the cursor rests beside the first row"
    assert still.black?(*cursor_pixel.call(2)), "and nowhere else"

    moved = assert_emulator_loads_rom(rom, frames: 6, keys: RubyGBA::Constants::KEY_DOWN)

    assert moved.white?(*cursor_pixel.call(2)),
           "holding down walks past the row that cannot be picked, to row 2"
  end

  def test_both_backends_draw_the_same_menu
    assert_backends_agree(menu_program, frames: 3)
  end
end
