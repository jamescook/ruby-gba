# frozen_string_literal: true

module CostAccuracy
  # The recorded corpus reading, and the check that nothing drifted further off.
  # See tools/cost_accuracy.rb for what this is for and what it found.
  module Baseline
    # What a run concluded. Pure: it compares two lists of readings and renders the
    # verdict, so it can be tested without building or measuring anything.
    class Verdict
      def initialize(recorded:, measured:)
        @recorded = recorded
        @measured = measured
      end

      def ok? = drifted.empty? && broken.empty?

      def render(out)
        failures(out)
        notes(out)
        out.puts(summary) if ok?
      end

      # Examples that moved further from the console than they were recorded at.
      def drifted
        @drifted ||= scorable.filter_map do |reading|
          was = @recorded[reading.name]
          next unless was && was[:distance]
          next unless reading.distance > was[:distance] * (1 + TOLERANCE)

          [reading.name, "#{fmt(was[:ratio])} → #{fmt(reading.ratio)} of the console"]
        end.to_h
      end

      # Examples that used to be readable and now are not — a game that stopped building,
      # or one that overran a frame where it used to fit. Not a ratio getting worse, but
      # not something to pass over either.
      def broken
        @broken ||= @measured.reject(&:scorable?).filter_map do |reading|
          was = @recorded[reading.name]
          [reading.name, reading.note] if was && was[:ratio]
        end.to_h
      end

      def improved
        @improved ||= scorable.select do |reading|
          was = @recorded[reading.name]
          was && was[:distance] && reading.distance < was[:distance] * (1 - TOLERANCE)
        end.map(&:name)
      end

      def unrecorded = scorable.map(&:name) - @recorded.keys

      # The corpus at a glance: how many are close, and which are furthest off. This is the
      # line worth reading even on a green run, because it says whether the model is getting
      # better across the board or only where somebody last looked.
      def summary
        scored = scorable
        return "No example could be scored." if scored.empty?

        close = scored.count { |r| r.distance <= 1.1 }
        worst = scored.max_by(3, &:distance).map { |r| "#{r.name} #{fmt(r.ratio)}" }
        "The estimate is within a tenth of the console on #{close} of #{scored.length} examples. " \
          "Furthest off: #{worst.join(', ')}."
      end

      private

      def scorable = @measured.select(&:scorable?)
      def fmt(ratio) = format("%.2fx", ratio)

      def failures(out)
        if drifted.any?
          out.puts "The estimate drifted further from the console:"
          drifted.each { |name, what| out.puts "  #{name}  #{what}" }
          out.puts
        end

        if broken.any?
          out.puts "These could be scored before and cannot now:"
          broken.each { |name, why| out.puts "  #{name}  #{why}" }
          out.puts
        end

        return if ok?

        out.puts "If that is the change you meant to make, accept the new readings with:"
        out.puts "  #{ACCEPT}"
        out.puts "and commit tools/cost_accuracy_baseline.json — the diff is what shows what moved."
        out.puts
      end

      # Never a failure. Getting closer is the whole point, and a baseline left worse than
      # the model actually is has slack in it that a later regression could hide inside.
      def notes(out)
        out.puts "Closer than recorded (re-record to lock it in): #{improved.join(', ')}." if improved.any?
        out.puts "Not in the baseline at all: #{unrecorded.join(', ')}." if unrecorded.any?
      end
    end

    module_function

    def rows(readings)
      readings.sort_by(&:name).to_h do |reading|
        [reading.name,
         { estimate: round(reading.estimate), measured: round(reading.measured),
           ratio: round(reading.ratio), distance: round(reading.distance), note: reading.note }.compact]
      end
    end

    def round(value) = value && value.to_f.round(3)

    def record(out: $stdout, path: PATH, only: nil)
      readings = CostAccuracy.current(only)
      before = read(path)
      Verdict.new(recorded: before, measured: readings).render(out) if before.any?
      write(path, rows(readings))
      scored = readings.count(&:scorable?)
      out.puts "Recorded #{readings.length} examples (#{scored} scorable) in #{relative(path)}."
      true
    end

    def check(out: $stdout, path: PATH, only: nil)
      recorded = read(path)
      if recorded.empty?
        out.puts "There is no baseline at #{relative(path)}. Write one with:"
        out.puts "  #{ACCEPT}"
        return false
      end

      verdict = Verdict.new(recorded: recorded, measured: CostAccuracy.current(only))
      verdict.render(out)
      verdict.ok?
    end

    def read(path = PATH)
      data = JSON.parse(File.read(path), symbolize_names: true)
      (data[:examples] || {}).transform_keys(&:to_s)
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    # Sorted and pretty-printed, because the diff is the thing a reviewer reads.
    def write(path, recorded)
      File.write(path, "#{JSON.pretty_generate({ version: VERSION, examples: recorded })}\n")
    end

    def relative(path) = path.to_s.delete_prefix("#{ROOT}/")
  end
end
