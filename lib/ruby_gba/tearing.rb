# frozen_string_literal: true

module RubyGBA
  # DID THE PICTURE TEAR? Measured, on a real run, rather than estimated.
  #
  # THE FOOTGUN THIS IS ABOUT. The display draws the screen one row at a time, top to
  # bottom, and it does not wait for the game. There is a brief gap between frames — the
  # vertical blank, about 68 rows' worth of time — where the game can change the picture
  # unseen. Draw for longer than that and the display starts showing the picture while the
  # game is still painting it: the top of the screen is the new frame and the bottom is
  # still the old one, with a seam between them that jumps about. That is a tear, and on a
  # single-buffered bitmap screen it is the classic way a first game goes wrong.
  #
  # HOW IT IS MEASURED, and the trick is that nothing had to be added to see it. The
  # emulator draws each row out of video memory as it reaches it, exactly as the console
  # does — so the picture it hands back is what the screen really showed, seam and all.
  # Video memory read AFTERWARDS, at the frame boundary where the game has finished its
  # work, is the picture the game meant to show. Compare the two: a row that differs is a
  # row the display put on screen before the game had finished with it.
  #
  # WHY IT CAN DISAGREE WITH THE ESTIMATE, and when it does it is the one that is right.
  # The estimate asks whether the drawing fits in the gap, which is a total. Whether it
  # TEARS depends on the race between two things travelling down the screen: the display's
  # row, and the game's. A fill that starts at the top when the gap starts can overrun the
  # gap and still stay ahead of the display the whole way down, and nothing tears —
  # measured at 92 rows' worth of drawing against a 68-row gap. So the estimate is
  # deliberately the cautious one, and this says what really happened.
  #
  # WHAT IT CANNOT ANSWER. It reads a framebuffer, so it needs a screen that has one and
  # only one: a direct-color bitmap screen. A tear-free screen keeps two pages and shows
  # the finished one, so it cannot tear and there is nothing to measure. A tiled screen
  # has no framebuffer at all — the console builds the picture from tiles as it draws.
  # Both answer {Reading.none}, which says "not measured here" rather than "no tear".
  #
  # AND A CLEAN PIXEL TEST IS NOT PROOF OF NO TEAR, which is worth knowing before hunting
  # one. A differential test compares the picture at rest, so a program whose drawing
  # FINISHES before the display reaches those rows comes back identical on both backends
  # while a heavier version of the same program tears. Days went into treating one of those
  # as a lowering bug, on the belief that a tear could not reach the emulator at all. This
  # is the thing to ask instead.
  module Tearing
    # Where the picture lives on a direct-color bitmap screen, and how big it is. Each
    # pixel is one 16-bit color, rows top to bottom, and the display shows exactly this.
    FRAMEBUFFER = Constants::VRAM_START
    WIDTH = IR::Screen::WIDTH
    HEIGHT = IR::Screen::HEIGHT

    # WHAT A RUN SAW. +rows+ is how many of the visible rows the display showed before the
    # game had finished them — 0 for a picture that held together. +first+ and +last+ are
    # where the seam ran, which is what a person wants to look at. A reading that does not
    # apply to this screen says so with #measured? false, so "we did not look" can never be
    # mistaken for "nothing was wrong".
    Reading = Data.define(:rows, :first, :last) do
      def self.none = new(rows: nil, first: nil, last: nil)

      def measured? = !rows.nil?
      def torn? = measured? && rows.positive?
    end

    module_function

    # Whether a tear can be measured on the screen this program runs. A framebuffer is
    # needed, and one that is not being flipped underneath the reading — see the class note.
    def measurable?(program)
      modes = IR::Modes.resolve(program)
      !modes.any_buffered? && !modes.any_tiled? && !modes.any_affine?
    end

    # Read one frame of +probe+ — already stepped to a frame boundary — and say how much of
    # the picture the display showed stale. The probe must be sitting at the boundary,
    # where the game has finished the frame being judged; that is where a step leaves it.
    def read(probe)
      shown = shown_rows(probe.frame_buffer)
      drawn = drawn_rows(probe)
      stale = (0...HEIGHT).select { |y| shown[y] != drawn[y] }
      Reading.new(rows: stale.length, first: stale.first, last: stale.last)
    end

    # The picture the display put on screen, a row at a time, as 15-bit colors — the same
    # numbers the program wrote, with the emulator's 8-bit channels shifted back down.
    def shown_rows(bytes)
      pixels = bytes.unpack("V*").map! do |word|
        ((word & 0xFF) >> 3) | (((word >> 8) & 0xFF) >> 3 << 5) | (((word >> 16) & 0xFF) >> 3 << 10)
      end
      (0...HEIGHT).map { |y| pixels[y * WIDTH, WIDTH] }
    end

    # The picture the game had finished drawing, read straight out of video memory.
    def drawn_rows(probe)
      (0...HEIGHT).map do |y|
        base = FRAMEBUFFER + (y * WIDTH * 2)
        (0...WIDTH).map { |x| probe.read16(base + (x * 2)) }
      end
    end
  end
end
