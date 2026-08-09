# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # Where each weight can be trusted, and saying so when a program leaves it.
      #
      # THE PROBLEM THIS EXISTS FOR. Nearly every weight in the model is a MARGINAL rate: two
      # ROMs that differ only in how many of the thing they do, differenced over the
      # difference. That is the right way to measure one more of something, and it has one
      # property worth understanding — it cancels everything the two ROMs share, INCLUDING
      # whatever the thing itself pays only once.
      #
      # So `mix_voice_sample` is measured with one voice sounding and with eight, and it
      # describes a mixer of one to eight voices. Asked about a regime far outside that, a rate
      # can be quietly wrong in a way no amount of re-reading the number would show — because a
      # weight on its own is a bare number in a hash with no memory of how it came to be.
      #
      # THE ASYMMETRY THIS CLOSES. A missing op is loud — #unpriced_kinds collects it, the
      # report banners it above everything else, and a new IR kind fails the suite until it is
      # priced. A weight used far outside where it was measured was silent. Both halves of
      # that were deliberate; only the first was finished.
      #
      # WHY ONLY SOME WEIGHTS ARE CHECKED. A domain is recorded for all of them, because that
      # is the documentation, but two things have to be true before a program can be measured
      # against one:
      #
      #   1. The weight has to have a COUNTABLE regime — a number a program chooses that
      #      changes the cost. About half do; an add costs what an add costs.
      #   2. The model has to be able to read that number out of a program. Two can be: a
      #      timer's ticks a frame, and how big a per-pixel collision walk is.
      #
      # And two more before it is worth SAYING:
      #
      #   3. Only FAR below the floor, and how far is not a guess. Write the true per-unit cost
      #      as r + F/n, where F is whatever the thing pays ONCE and n is the count. At the
      #      count it was measured, F/n was small enough to disappear into the rate; at a tenth
      #      of that count it is ten times bigger. So the error scales as 1/n, and an order of
      #      magnitude below the measurement is where it stops being noise. Extrapolating a
      #      linear rate UP is harmless, so above the range says nothing.
      #
      #      That reasoning also says what the real fix for such a weight is: measure F and
      #      charge it. A loop is the worked example — loop_start is F, and once it is priced
      #      the rate holds at one pass as well as at nine hundred, so a loop has no regime to
      #      be warned about at all.
      #   4. Only when it is material. A weight a sixth wrong about 0.2 scanlines is not a
      #      finding, and a report that says so anyway teaches people to skip the section. That
      #      threshold is what keeps this from becoming noise.
      module Domains
        # Below this many scanlines of the frame, being wrong about a weight does not change any
        # decision, so there is nothing worth saying.
        MATERIAL = 1.0

        # How far below the measured floor a count must fall before the excluded fixed cost is
        # worth mentioning: an order of magnitude, for the reason above.
        FAR_BELOW = 0.1

        # The weights whose regime the model can read out of a program, and the method that
        # reads it. The others' domains are recorded and never checked — either they have no
        # countable regime, or nothing in a program names their count.
        PROBES = {
          tick_interrupt: :tick_uses,
          overlap_pixel: :overlap_uses,
        }.freeze

        # Where this program asks a weight for an answer from outside where that weight was
        # measured, and it matters. Each entry:
        #   { weight:, varies:, from:, to:, count:, cost:, what: }
        def domain_notes(program)
          index(program)
          PROBES.flat_map do |weight, probe|
            domain = weight_domain(weight)
            next [] unless domain[:varies] && domain[:from]

            send(probe, program).filter_map { |use| note_for(weight, domain, use) }
          end
        end

        # What the calibration recorded about where +weight+ was measured, as a plain Hash
        # ({} when it recorded nothing). Written by tools/calibrate_cost_model.rb.
        def weight_domain(weight)
          domains = self.class.const_defined?(:WEIGHT_DOMAINS) ? self.class::WEIGHT_DOMAINS : {}
          domains[weight] || {}
        end

        # Say it, in the same voice the unpriced-op banner uses and for the same reason: the
        # estimate is admitting something about itself rather than reporting on the program.
        # It goes at the top, above the numbers it applies to.
        #
        # It names the weight, because that is what somebody has to go and re-measure, and it
        # says which way the estimate is wrong — under, always, since a marginal rate leaves
        # out what the thing pays once.
        def emit_domain_banner(printer, program)
          domain_notes(program).each do |note|
            printer.puts "!! #{note[:what]}: #{note[:weight]} was measured over " \
                         "#{fmt_count(note[:from])}..#{fmt_count(note[:to])} #{note[:varies]}, so " \
                         "~#{fmt(note[:cost])} scanlines of this frame reads LOW. A marginal rate " \
                         "leaves out what a thing pays once. Re-measure #{note[:weight]} near " \
                         "#{fmt_count(note[:count])} to be sure.",
                         emphasis: :banner
          end
        end

        private

        def fmt_count(count) = count.to_i == count ? count.to_i.to_s : format("%.1f", count)

        def note_for(weight, domain, use)
          return nil unless use[:count] < domain[:from] * FAR_BELOW
          return nil if use[:cost] < MATERIAL

          { weight: weight, varies: domain[:varies], from: domain[:from], to: domain[:to],
            count: use[:count], cost: use[:cost], what: use[:what] }
        end

        # Every timer that runs a tick handler, with how many times a frame it ticks.
        def tick_uses(program)
          (tick_verdict(program)&.fetch(:timers) || []).map do |timer|
            { what: "timer :#{timer[:name]} at #{timer[:hz]} a second", count: timer[:ticks],
              cost: timer[:interrupts] }
          end
        end

        # Every per-pixel collision test, with how many cells its overlap can cover at worst.
        def overlap_uses(program)
          program.walk.select { |node| node.kind == :pixels_overlap }.filter_map do |node|
            cells = overlap_cells(node)
            next nil unless cells.positive?

            { what: "a per-pixel collision over #{cells} cells", count: cells,
              cost: cells * @weights[:overlap_pixel] }
          end
        end
      end
    end
  end
end
