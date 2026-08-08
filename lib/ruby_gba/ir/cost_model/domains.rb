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
      # So `loop_pass` was measured on loops of 300 and 900 passes, and it describes a loop of
      # 300 to 900 passes. A four-pass loop pays its setup over four passes instead of
      # hundreds, and the rate says nothing about that: measured, an eighth of the cost is
      # missing. Nothing in the model knew to mention it, because a weight was a bare number
      # in a hash with no memory of how it came to be.
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
      #   2. The model has to be able to read that number out of a program. Three can be:
      #      a loop's trip count, a timer's ticks a frame, and how big a per-pixel collision
      #      walk is.
      #
      # And two more before it is worth SAYING:
      #
      #   3. Only FAR below the floor, and how far is not a guess. Write the true per-unit cost
      #      as r + F/n, where F is whatever the thing pays ONCE and n is the count. At the
      #      count it was measured, F/n was small enough to disappear into the rate; at a tenth
      #      of that count it is ten times bigger. So the error scales as 1/n, and an order of
      #      magnitude below the measurement is where it stops being noise. On the one weight
      #      we know is affected that lands exactly right: loop_pass reads 0.87x at 4 passes
      #      (an order below its floor of 300) and 0.95x at 40 — the first is worth saying, the
      #      second is inside the model's usual band. Extrapolating a linear rate UP is
      #      harmless, so above the range says nothing.
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
          loop_pass: :loop_pass_uses,
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

        # Every counted loop a frame runs, with how many passes it makes and what its
        # BOOKKEEPING costs the frame — the counter, the compare and the jump back, which is
        # the part `loop_pass` prices and the part whose weight has a floor.
        #
        # Nesting is followed and multiplied, so a four-pass loop inside a sixty-pass one is
        # counted at the 240 passes a frame really makes. A loop inside a routine is counted
        # once per entry to that routine rather than per call to it, which under-counts a
        # routine called many times a frame — the safe direction, since it means fewer notes
        # rather than notes about nothing.
        def loop_pass_uses(program)
          uses = []
          gather_loops(steady_statements(program), 1, uses)
          program.walk.each { |node| gather_loops(node.children, 1, uses) if node.kind == :func }
          uses
        end

        def gather_loops(nodes, multiplier, uses)
          nodes.each do |node|
            unless node.kind == :repeat
              gather_loops(node.children, multiplier, uses)
              next
            end

            passes = repeat_factor(node).first
            if passes.positive?
              uses << { what: "a repeat of #{passes} #{passes == 1 ? 'pass' : 'passes'}",
                        count: passes, cost: multiplier * passes * @weights[:loop_pass] }
            end
            gather_loops(node.children, multiplier * [passes, 1].max, uses)
          end
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
