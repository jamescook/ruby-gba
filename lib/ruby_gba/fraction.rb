# frozen_string_literal: true

module RubyGBA
  # Numbers that carry a fraction, and the rules for doing arithmetic on them.
  #
  # THE PROBLEM. A variable on this console holds whole numbers. A game that needs
  # halves and quarters — a speed, an angle, a position between two tiles — keeps its
  # numbers multiplied up by a fixed amount and divides back at the end. That works,
  # and it is what every game on the machine does. What it costs is that the author
  # now holds a number in their head for every variable: this one is multiplied up by
  # 65536, that one by 256, this one not at all. Nothing checks it. Add two that
  # disagree and the answer is silently wrong.
  #
  # WHAT THE EVIDENCE SAID. examples/raycaster.rb was written the explicit way first,
  # so the design could be argued from real code rather than from first principles.
  # Three things showed up there, and they are what these rules answer:
  #
  #   1. The scale was written into every line that touched a position. `(3 * FIXED)
  #      + (FIXED / 2)` to say "three and a half". `rx / FIXED` to ask which cell. The
  #      author cannot say the thing they mean.
  #
  #   2. Of the three multiplies of two fractions in that file, only ONE actually
  #      overflowed. The other two were safe only because the walking speed happened
  #      to be small. Nothing said which was which — knowing meant working out the
  #      range of both operands in your head, and being wrong was silent. This is the
  #      strongest argument for the type: not that `fraction_bits: 16` is tedious to
  #      type, but that a person cannot reliably tell when they need it.
  #
  #   3. Asking which cell a position is in was a DIVISION, and the console has no
  #      divide instruction — every one of those trapped into a BIOS routine. Sixty
  #      of them per screen column. The conversion has to be cheap or the type is a
  #      tax on the very code that needs it most.
  #
  # THE RULES. A Value may carry a number of fraction bits. The scale then travels
  # WITH the value through arithmetic, so it is declared once and never repeated:
  #
  #   px = var :px, 3.5          # a Float initial value: this variable holds a fraction
  #   px.add speed               # speed carries a fraction too — plain addition
  #   px.to_i                    # a whole number again, for a pixel or an array index
  #
  # A Float anywhere in the program means "a number with a fraction", which is what a
  # Ruby programmer already believes. The phrase "fixed point" never appears, and
  # neither does the scale.
  #
  # Adding and comparing need both sides at the SAME scale, so:
  #   - two fractions at the same scale: straight through.
  #   - a fraction and a plain WHOLE NUMBER WRITTEN IN THE PROGRAM: the number is
  #     converted for you, because `speed + 1` plainly means one faster. Free — it
  #     happens while building.
  #   - a fraction and a plain value the game works out: a build error. There is no
  #     way to tell whether a counter of 3 means three, or three sixty-fourths.
  #   - two fractions at different scales: a build error.
  #
  # Multiplying is different, and this is the part worth reading twice. Multiplying a
  # fraction by a plain COUNT is ordinary multiplication and keeps the scale — twice
  # as fast is twice as fast. Multiplying two FRACTIONS is the operation that
  # overflows, so it becomes mul_fix automatically. The author no longer has to know
  # which of their multiplies is the dangerous one, which is the whole point.
  #
  # Dividing a fraction by a plain count is ordinary division. Dividing a fraction BY
  # a fraction is a build error: doing it correctly needs the numerator shifted up
  # first, which does not fit in a variable, and there is no 64-bit divide to lean on.
  # The friendly error says to use a `table` of the answers instead, which is what a
  # raycaster does for exactly this reason.
  #
  # WHY THE SCALE LIVES IN RUBY AND NOT IN THE IR. A Value is a build-time handle, so
  # the scale is known while the program is being built and can be checked there. The
  # tree that comes out the other end is ordinary integer arithmetic — the same nodes
  # a whole-number program builds, plus mul_fix and shift_right where they are needed.
  # So a backend has nothing to learn, the two backends cannot disagree about scales
  # because neither of them sees one, and a fraction costs nothing at run time that
  # the hand-written version did not also cost.
  module Fraction
    # How many bits of fraction a Float gets when the program does not say otherwise.
    # 16 leaves about four decimal places and room for positions across a large world;
    # it is the scale most GBA games use for anything that moves.
    DEFAULT_BITS = 16

    module_function

    # A Float as a whole number carrying +bits+ fraction bits: 1.5 with 16 bits is
    # 1.5 * 65536. Rounded, because the nearest representable number is the one the
    # author meant.
    def scale(number, bits)
      (number * (1 << bits)).round
    end

    # The number of fraction bits an operand carries, or nil if it is a plain whole
    # number. A Float carries the default scale — writing one is how you say so.
    def bits_of(operand)
      case operand
      when Value then operand.fraction_bits
      when Float then DEFAULT_BITS
      end
    end

    # Whether +operand+ is a number written into the program (as opposed to something
    # the game works out as it runs). Only these can be converted to another scale for
    # free, because the conversion happens while building.
    def literal?(operand)
      operand.is_a?(Numeric)
    end
  end
end
