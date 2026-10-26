#!/usr/bin/env ruby
# frozen_string_literal: true

# Clock — the time and the date, in big letters, and nothing else.
#
# The console has no clock of its own. Switched off it forgets everything, and switched on it
# only knows how long it has been running. Some cartridges carry a clock chip with a watch
# battery of its own, which keeps counting while the console is off, and `clock` is how a game
# asks it. Its readings are numbers like any variable's: draw them, compare them, keep them.
#
# Two things here are worth copying into a game of your own.
#
# ASK FIRST. A cartridge may have no clock at all — most emulators give a cartridge none unless
# they are told to — and a clock whose battery ran out was never set. Either way every reading
# is 0, so a game that does not ask shows 00:00:00 and looks broken. This one says which it is.
#
# mGBA says NO CLOCK until it is told this game has one: it switches the clock on by itself only
# for the retail games it knows, and its Game Overrides window cannot do it for a game of your
# own. Its settings file can. With mGBA closed, add these two lines to the end of its config.ini
# (~/.config/mgba/config.ini on a Mac or Linux), where HE6F is the game code `ruby-gba inspect
# clock.gba` prints and 1 means "this cartridge has a clock":
#
#   [override.HE6F]
#   hardware=1
#
# The clock also works in SkyEmu.
#
# FOR THE ADVANCE ALONE. A Game Boy Color cartridge's clock counts days and keeps no date, so a
# game there shows the time only once it sets the clock (`clock.set_to`), from a screen of its own
# that asks the player; this one never asks, and on a Color would only ever say it was not set.
#
# PAINT WHEN IT CHANGES. The time moves on once a second, so the face is painted once a second
# and left alone in between, through `keep_showing`. The screen here keeps two pictures and
# shows them in turn, so that nobody ever sees one half drawn; `keep_showing` is what paints a
# change into both, where painting it once would flicker between the new second and the old.
#
# Run it to build examples/clock.gba:
#   ruby examples/clock.rb

require_relative "../lib/vblank"

module ClockFace
  LETTERS = VBlank::Graphics::Fonts.default

  SCREEN_W = 240

  # How many times bigger than the built-in letters each line is drawn, and the font of that
  # size each one is drawn in.
  BIG = 3
  SMALL = 2
  SCALE_OF = Ractor.make_shareable({ big: BIG, small: SMALL })

  # Where each line's top edge is. Every line is centered across the screen.
  TIME_ROW = 40
  DATE_ROW = 86
  DAY_ROW = 108

  INK = :white
  BACKGROUND = :black

  # The clock counts the days of the week from Sunday, as 0.
  DAYS = Ractor.make_shareable(%w[SUNDAY MONDAY TUESDAY WEDNESDAY THURSDAY FRIDAY SATURDAY])

  NO_CLOCK = "NO CLOCK"
  NOT_SET = "NOT SET"

  # Each character of +chars+ in the built-in letters, every pixel made a +scale+ by +scale+
  # square: a picture per letter, which is what `font` takes for a font of the game's own.
  def self.blown_up(chars, scale)
    chars.chars.uniq.to_h do |char|
      rows = Array.new(LETTERS.height * scale) { Array.new(LETTERS.width * scale, 0) }
      LETTERS.each_pixel(char) do |x, y|
        (0...scale).each { |dy| (0...scale).each { |dx| rows[(y * scale) + dy][(x * scale) + dx] = 1 } }
      end
      [char, rows]
    end
  end

  # The left edge that centres +length+ characters of a font +scale+ times the built-in one.
  def self.centered(length, scale)
    width = (length * LETTERS.cell_w * scale) - (LETTERS.spacing * scale)
    (SCREEN_W - width) / 2
  end

  GAME = VBlank.game("CLOCK", consoles: %i[gba]) do
    screen :bitmap, tear_free: true

    font :big, glyphs: ClockFace.blown_up("0123456789: #{NO_CLOCK}#{NOT_SET}", BIG), spacing: BIG
    font :small, glyphs: ClockFace.blown_up("0123456789-#{DAYS.join}", SMALL), spacing: SMALL

    now = clock

    # A number of two figures, with a nought in front of one below ten, as a clock shows it:
    # `draw_number` leaves a leading nought blank, so the tens and the ones are drawn as a
    # figure each.
    two_figures = lambda do |number, column, row, font|
      draw_number number / 10, column, row, INK, digits: 1, font: font
      draw_number number % 10, column + (LETTERS.cell_w * SCALE_OF[font]), row, INK, digits: 1, font: font
    end

    face = keep_showing :face do
      clear_screen BACKGROUND

      (now.present? & now.set?).then do
        # 21:07:05 — eight characters, a pair of figures in the first, fourth and seventh places.
        left = ClockFace.centered(8, BIG)
        step = LETTERS.cell_w * BIG
        two_figures.call(now.hour, left, TIME_ROW, :big)
        draw_text ":", left + (2 * step), TIME_ROW, INK, font: :big
        two_figures.call(now.minute, left + (3 * step), TIME_ROW, :big)
        draw_text ":", left + (5 * step), TIME_ROW, INK, font: :big
        two_figures.call(now.second, left + (6 * step), TIME_ROW, :big)

        # 2026-10-22 — ten characters.
        left = ClockFace.centered(10, SMALL)
        step = LETTERS.cell_w * SMALL
        draw_number now.year, left, DATE_ROW, INK, digits: 4, font: :small
        draw_text "-", left + (4 * step), DATE_ROW, INK, font: :small
        two_figures.call(now.month, left + (5 * step), DATE_ROW, :small)
        draw_text "-", left + (7 * step), DATE_ROW, INK, font: :small
        two_figures.call(now.day, left + (8 * step), DATE_ROW, :small)

        DAYS.each_with_index do |name, weekday|
          (now.weekday == weekday).then { draw_text name, :center, DAY_ROW, INK, font: :small }
        end
      end.else do
        now.present?.then { draw_text NOT_SET, :center, TIME_ROW, INK, font: :big }
                    .else { draw_text NO_CLOCK, :center, TIME_ROW, INK, font: :big }
      end
    end

    # The second the face shows. It starts at one the clock never reads, so the first pass paints.
    shown = var :shown, -1

    game_loop do
      (now.second != shown).then do
        shown.set! now.second
        face.changed
      end
      face.draw
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

ClockFace::GAME.write_if_main
