# frozen_string_literal: true

module RubyGBA
  module IR
    # A printer every report writes its lines through, so *how* a line looks — coloured,
    # a bold group heading, or nothing at all — is decided in one place and swapped
    # wholesale: plain text when the output is a file or a pipe, ANSI colour when it is a
    # terminal. A report hands each line its *meaning* (how bad the news is, whether it is
    # a group heading); the printer decides how to show it.
    #
    # Two printers implement the same interface — #puts(text, severity:, emphasis:) for
    # ordinary lines and #cost_line(label, value, severity:, group:) for a row of the
    # drill-down tree: {PlainPrinter} (verbatim — the exact output from before colours
    # existed) and {ColorPrinter}. {Printer.for} picks between them.
    class Printer
      # A tree row is "  <label padded to LABEL_WIDTH> ~<value>", so the value column
      # lines up. Kept here (not in the cost model) so both printers lay a row out
      # identically — the plain one and the coloured one differ only in styling.
      LEAD = "  "
      LABEL_WIDTH = 52

      # Pick a printer for +out+. `color: :auto` (the default) tints only when it's safe
      # to — a real terminal, with the standard NO_COLOR variable unset — so a report
      # captured to a StringIO or piped to a file stays plain automatically. `true` and
      # `false` force colour on or off (the eventual `--no-color` flag passes `false`).
      def self.for(out, color: :auto)
        colored = color == true || (color == :auto && ansi_ok?(out))
        colored ? ColorPrinter.new(out) : PlainPrinter.new(out)
      end

      # Whether it's safe to emit ANSI colour to +out+: only to an interactive terminal,
      # and never when NO_COLOR is set (present and non-empty — the no-color.org rule).
      def self.ansi_ok?(out)
        return false if ENV["NO_COLOR"].to_s != ""

        out.respond_to?(:tty?) && out.tty?
      end

      def initialize(out)
        @out = out
      end

      # The plain "  label…            ~value" layout shared by both printers, so a
      # coloured row is the same characters as a plain one plus zero-width styling.
      def layout(label, value)
        format("#{LEAD}%-#{LABEL_WIDTH}s ~%s", label, value)
      end
    end

    # Every line verbatim, ignoring severity and emphasis — byte-for-byte the output
    # from before colours existed, so a captured or piped report is unchanged.
    class PlainPrinter < Printer
      def puts(text, severity: nil, emphasis: nil)
        @out.puts(text)
      end

      def cost_line(label, value, severity: nil, group: false)
        @out.puts(layout(label, value))
      end
    end

    # Wraps a line in ANSI codes. A group heading (a file subtotal) is additionally bold,
    # with an underline under just its indent-and-label — not trailing across the padding
    # to the value — so the heading reads as a heading without a rule drawn across the
    # whole row.
    class ColorPrinter < Printer
      RESET = "\e[0m"
      BOLD = "\e[1m"
      UNDERLINE = "\e[4m"
      UNDERLINE_OFF = "\e[24m"
      RED = "\e[31m"

      # WHAT A LINE'S MEANING LOOKS LIKE. There is one meaning today, and red is the right
      # answer for it: `bad` is a report's picture verdicts — the game tore, half its
      # drawing never arrived, sounds it asked for did not play — and each of those lines
      # is printed ONLY when it really happened. A run that came out right prints none of
      # them and so shows no colour at all.
      #
      # That is the whole rule for red here, and it is worth keeping: red is an alarm a
      # person has to act on, never a label for "this is the biggest number". A report
      # that reddens a healthy game teaches people to scroll past red, and then it says
      # nothing when it matters.
      COLORS = { bad: RED }.freeze

      # The unpriced banner is bold red on its own (no per-line severity).
      EMPHASIS = { banner: "#{BOLD}#{RED}" }.freeze

      # A MEANING NOBODY GAVE A COLOUR LEAVES THE LINE ALONE, and that is deliberate rather
      # than lax. Asking for a colour that is not there used to raise, and the lines that
      # carry a meaning are exactly the ones printed when something has already gone wrong —
      # so a name that did not match killed the report at the moment it had bad news, and
      # the plain printer ignores meanings entirely, so nothing anywhere else noticed. A
      # missing colour is worth an uncoloured line; it is never worth the finding.
      def puts(text, severity: nil, emphasis: nil)
        codes = "#{EMPHASIS[emphasis]}#{COLORS[severity]}"
        @out.puts(codes.empty? ? text : "#{codes}#{text}#{RESET}")
      end

      def cost_line(label, value, severity: nil, group: false)
        tint = COLORS[severity].to_s
        return @out.puts(group ? heading(label, value, tint) : "#{tint}#{layout(label, value)}#{RESET}") if tint != "" || group

        @out.puts(layout(label, value))
      end

      private

      # A group heading: bold and tinted across the whole row (invisible on the padding
      # spaces, wanted on the value), but underlined only under the lead indent and the
      # label text, stopping before the padding — so no rule runs to the value column.
      def heading(label, value, tint)
        shown = label[0, [label.length, LABEL_WIDTH].min] # the label without its trailing pad
        rest = layout(label, value)[(LEAD.length + shown.length)..] # padding + " ~value"
        "#{tint}#{BOLD}#{UNDERLINE}#{LEAD}#{shown}#{UNDERLINE_OFF}#{rest}#{RESET}"
      end
    end
  end
end
