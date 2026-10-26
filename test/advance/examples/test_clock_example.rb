# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/clock").to_s

# The clock example (examples/clock.rb): the time and the date in big letters, read from the
# clock the cartridge carries. The test starts the clock at a moment of its own, the way it
# holds buttons, and reads the words off the screen.
#
# The words are checked against the built-in letters blown up by the example's sizes, worked out
# here pixel by pixel, so a wrong digit, a letter out of place or a smear left from the second
# before all fail: every pixel of a line's box is either ink where a letter is lit or the
# background where it is not.
class TestClockExample < Minitest::Test
  LETTERS = VBlank::Graphics::Fonts.default
  INK = Color.resolve(ClockFace::INK)
  BACKGROUND = Color.resolve(ClockFace::BACKGROUND)

  # A Thursday evening, and a second before a new year.
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)
  NEW_YEARS_EVE = Time.new(2026, 12, 31, 23, 59, 59)

  # The first frame is the game setting up; by the third the face has been painted.
  SETTLED = 3
  # A console frame is a little more than a sixtieth of a second, so the second turns over on
  # the sixtieth frame.
  A_SECOND_LATER = SETTLED + 61

  private def face_after(frames, start = nil, set: true)
    player = game_player
    player = player.clock_at(start, set: set) if start
    player.run(ClockFace.program, frames: frames).screen
  end

  # Whether the line at row +y+ says +text+ in the built-in letters made +scale+ times bigger,
  # centered on the screen, and nothing else in its box. +pixel+ reads one pixel of a picture.
  private def pixels_say?(text, y, scale, &pixel)
    cell = LETTERS.cell_w * scale
    width = (text.length * cell) - (LETTERS.spacing * scale)
    left = (240 - width) / 2
    lit = {}
    LETTERS.each_pixel(text) { |x, row| lit[[x, row]] = true }
    (0...(LETTERS.height * scale)).all? do |dy|
      (0...width).all? do |dx|
        want = lit[[dx / scale, dy / scale]] ? INK : BACKGROUND
        pixel.call(left + dx, y + dy) == want
      end
    end
  end

  private def screen_says?(screen, text, y, scale) = pixels_say?(text, y, scale) { |x, py| screen.pixel(x, py) }

  private def time?(screen, text) = screen_says?(screen, text, ClockFace::TIME_ROW, ClockFace::BIG)
  private def date?(screen, text) = screen_says?(screen, text, ClockFace::DATE_ROW, ClockFace::SMALL)
  private def day?(screen, text) = screen_says?(screen, text, ClockFace::DAY_ROW, ClockFace::SMALL)

  def test_it_shows_the_time_and_the_date_it_was_started_at
    face = face_after(SETTLED, THURSDAY)

    assert time?(face, "21:07:05"), "the time, with a nought in front of the minutes and the seconds"
    assert date?(face, "2026-10-22"), "the date"
    assert day?(face, "THURSDAY"), "and the name of the day"
  end

  def test_a_second_later_the_seconds_have_moved_on
    face = face_after(A_SECOND_LATER, THURSDAY)

    assert time?(face, "21:07:06"), "repainted as the second turned over, with nothing of the 05 left"
  end

  def test_a_second_after_new_years_eve_it_shows_the_new_year
    face = face_after(A_SECOND_LATER, NEW_YEARS_EVE)

    assert time?(face, "00:00:00")
    assert date?(face, "2027-01-01")
    assert day?(face, "FRIDAY")
  end

  # Most emulators give a cartridge no clock unless told to, so this is what a player sees first.
  def test_with_no_clock_it_says_so
    assert time?(face_after(SETTLED), "NO CLOCK")
  end

  def test_a_clock_never_set_says_so
    assert time?(face_after(SETTLED, Time.new(2000, 1, 1), set: false), "NOT SET")
  end

  def test_the_console_shows_the_time_its_clock_chip_reads
    require_emulator!
    rom = ClockFace.build_rom(out: StringIO.new, err: StringIO.new)
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 10, clock: THURSDAY)

    assert pixels_say?("21:07:05", ClockFace::TIME_ROW, ClockFace::BIG) { |x, y| v.pixel_gba(x, y) },
           "the cartridge read its chip and painted the time"
  end
end
