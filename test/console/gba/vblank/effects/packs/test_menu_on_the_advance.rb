# frozen_string_literal: true

require "test_helper"

require "differential"

# THE TESTS OF vblank/effects/packs/test_menu.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# `menu` — a list of rows, a cursor that moves between them, and a block per row.
#
# These tests read the PICTURE, not the pick variable. Where the cursor sits is the
# thing a player can see, so a test that finds the cursor by looking for it would
# still catch a menu that moved its pick and drew somewhere else. The rows are given
# distinct colours for the same reason: "picked" is a colour on the screen, not a
# flag in memory.
class TestMenuOnTheAdvance < Minitest::Test
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
  private def menu_program(press: :a, repeat_every: nil, on: :bitmap, starts_on: nil, &extra)
    build_program do
      screen on
      var :chose, 0
      game_loop do
        clear_screen :black if on == :bitmap
        options = { at: [X, Y], spacing: SPACING, color: :gray, picked: :white,
                    disabled: :red, press: press }
        options[:repeat_every] = repeat_every if repeat_every
        options[:starts_on] = starts_on if starts_on
        m = menu(:main, **options) do |rows|
          ROWS.each_with_index do |label, i|
            rows.item(label, enabled: i != 1) { set! :chose, i + 1 }
          end
        end
        instance_exec(m, &extra) if extra
      end
    end
  end

  private def build_program(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # Run a program, feeding it a fresh set of held buttons each frame.
  private def walk(program, frames:, &keys)
    interp = game_player
    interp = interp.input_each_frame(&keys) if keys
    interp.run(program, frames: frames)
    interp
  end

  NOTHING_HELD = ->(_frame) { [] }

  # Which row the cursor is drawn beside, or nil if it is nowhere.
  private def cursor_row(interp, column = X)
    ROWS.each_index.find { |row| lit?(interp, column - CURSOR_W, row) }
  end

  # The colour a row's label is drawn in, or nil if the row drew nothing.
  private def row_color(interp, row)
    top = Y + (row * SPACING)
    (X...(X + 60)).each do |x|
      (0...7).each do |dy|
        px = interp.screen.pixel(x, top + dy)
        return px if px && px.positive?
      end
    end
    nil
  end

  private def lit?(interp, x, row)
    top = Y + (row * SPACING)
    (x...(x + CURSOR_W)).any? do |px|
      (0...7).any? { |dy| interp.screen.pixel(px, top + dy).to_i.positive? }
    end
  end

  # ---- where the cursor starts, and what the rows look like ----

  # ---- moving ----

  # ---- held-button repeat ----

  # Counting the moves rather than reading the row the walk ended on: a menu that
  # raced down the list one row a frame can land on the right row by coincidence, and
  # in a three-row walk it often does.
  private def counting_moves(repeat_every:)
    menu_program(repeat_every: repeat_every) { |m| m.moved.then { add! :chose, 1 } }
  end

  # ---- choosing ----

  # ---- the pick is remembered ----

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
  private def settings_menu(&extra)
    build_program do
      screen :bitmap
      music = var :music, 1
      game_loop do
        clear_screen :black
        menu(:main, at: [X, Y], spacing: SPACING, color: :gray, picked: :white) do |rows|
          rows.item(["MUSIC OFF", "MUSIC ON"], showing: music) { music.set! 1 - music }
          rows.item("START")
        end
        instance_exec(music, &extra) if extra
      end
    end
  end

  # The two labels differ in length, so how far the row reaches says which one is up.
  private def row_extent(interp, row)
    top = Y + (row * SPACING)
    lit = (0...240).select { |x| (0...7).any? { |dy| interp.screen.pixel(x, top + dy).to_i.positive? } }
    lit.empty? ? nil : lit.last
  end

  private def interp_pixel(interp, x, y)
    interp.screen.pixel(x, y).to_i
  end

  # ---- friendly errors ----

  # ---- on a tiled screen ----
  #
  # There is no framebuffer there: the console composites the picture, and every
  # character of every row is one little 8x8 sprite it draws for you. So the same menu
  # is built out of something completely different — and the point of these tests is
  # that a game cannot tell, because they are the bitmap tests again with one word
  # changed.

  private def tiled_menu(**options, &extra)
    menu_program(on: :tiled, **options, &extra)
  end

  # A long menu, for counting sprites with. 12 rows of 12 characters is past the
  # console's 128; 8 rows of 10 is not.
  private def long_menu(rows_of:, on: :tiled)
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

  private def sprites_in(program)
    program.walk.count { |node| node.kind == :object }
  end

  # ---- the guardrail ----

  private def warnings(program)
    VBlank::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  # ---- on the console ----

  # ---- a row that can be picked only while the game says so ----
  #
  # A Continue row greyed until there is a save; Resume greyed unless a game is running.
  # Row TWO can be picked while `open` is 1 (said as a test), row THREE while `open` is not
  # 0 (said as the variable itself). L opens and closes both.

  private def changing_menu(on: :bitmap, opens_at: nil, repeat_every: nil)
    build_program do
      screen on
      var :chose, 0
      open = var :open, 0
      t = var :t, 0
      game_loop do
        clear_screen :black if on == :bitmap
        t.add! 1
        pressed(:l).then { open.set! 1 - open }
        (t == opens_at).then { open.set! 1 } if opens_at
        options = { at: [X, Y], spacing: SPACING, color: :gray, picked: :white, disabled: :red }
        options[:repeat_every] = repeat_every if repeat_every
        menu(:main, **options) do |rows|
          rows.item("ONE") { set! :chose, 1 }
          rows.item("TWO", enabled: open == 1) { set! :chose, 2 }
          rows.item("THREE", enabled: open) { set! :chose, 3 }
          rows.item("FOUR") { set! :chose, 4 }
        end
      end
    end
  end

end
