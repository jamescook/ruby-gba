# frozen_string_literal: true

require "json"
require_relative "emitted"

module Emitted
  # A recorded size for every example, and a check that nothing has grown past it.
  #
  #   rake emitted:record   write tools/emitted_baseline.json
  #   rake emitted:check    build now, compare, fail if anything grew
  #
  # `rake emitted` answers "what did the last hour cost", with no bookkeeping. This
  # answers a question no ad-hoc comparison can: has anything crept up since we last
  # agreed a number. A change that adds four instructions to every example is
  # invisible one commit at a time and obvious against a recorded baseline.
  #
  # GROWTH IS A FAILURE, however small, because the build is reproducible: the same
  # program always lowers to the same bytes (see test_build_reproducibility.rb), so
  # there is no noise for a tolerance to absorb, and a tolerance would only be a
  # budget for creep. Deliberate growth is accepted by re-recording, which is one
  # command and leaves a reviewable diff — that diff is the point, since it is where
  # a reviewer sees what a feature cost.
  #
  # Per example rather than one total: a program that shrank would otherwise mask
  # one that grew.
  #
  # The frame-work estimate is deliberately NOT recorded. It is an estimate whose
  # weights are re-measured from the emulator now and then, so it would churn for
  # reasons that have nothing to do with the emitted code this file is guarding.
  module Baseline
    PATH = File.join(ROOT, "tools", "emitted_baseline.json")
    VERSION = 1
    ACCEPT = "rake emitted:record"

    # What a run of the check concluded. Pure: it compares two maps of
    # name => { code:, data: } and renders the verdict, so it can be tested without
    # building anything.
    class Verdict
      def initialize(recorded:, measured:, errors: {})
        @recorded = recorded
        @measured = measured
        @errors = errors
      end

      def ok? = grew.empty? && unrecorded.empty? && @errors.empty?

      def render(out)
        failures(out)
        notes(out)
        out.puts(ok? ? "Emitted code is within the recorded baseline (#{@measured.size} examples)." : nil)
      end

      # Examples bigger than their recorded size, as readable lines.
      def grew
        @grew ||= @measured.filter_map do |name, now|
          then_ = @recorded[name]
          next unless then_

          parts = []
          parts << growth("code", then_[:code], now[:code], :instructions)
          parts << growth("data", then_[:data], now[:data], :bytes)
          parts.compact!
          parts.empty? ? nil : [name, parts.join(", ")]
        end.to_h
      end

      def shrank
        @shrank ||= @measured.select do |name, now|
          then_ = @recorded[name]
          then_ && !grew.key?(name) && (now[:code] < then_[:code] || now[:data] < then_[:data])
        end.keys
      end

      def unrecorded = @measured.keys - @recorded.keys
      def gone = @recorded.keys - @measured.keys

      private

      def growth(what, before, now, unit)
        return nil unless before && now && now > before

        delta = now - before
        delta = "#{delta / BYTES_PER_INSTRUCTION} instructions" if unit == :instructions &&
                                                                   (delta % BYTES_PER_INSTRUCTION).zero?
        "#{what} #{before} → #{now} (+#{delta}#{unit == :bytes ? ' bytes' : ''})"
      end

      def failures(out)
        @errors.each { |name, message| out.puts "#{name} does not build: #{message}" }
        out.puts if @errors.any?

        if grew.any?
          out.puts "Emitted code has grown past the recorded baseline:"
          grew.each { |name, what| out.puts "  #{name}  #{what}" }
          out.puts
        end

        if unrecorded.any?
          out.puts "Not in the baseline at all: #{unrecorded.join(', ')}."
          out.puts
        end

        return if ok?

        out.puts "If that is the change you meant to make, accept the new numbers with:"
        out.puts "  #{ACCEPT}"
        out.puts "and commit tools/emitted_baseline.json — the diff is what shows the cost."
        out.puts
      end

      # Never a failure: shrinking is the good direction. Worth saying, because a
      # baseline left above what the code actually emits has slack in it, and a later
      # regression back up to the old number would pass unnoticed.
      def notes(out)
        out.puts "Smaller than recorded (re-record to lock it in): #{shrank.join(', ')}." if shrank.any?
        out.puts "Recorded but no longer present: #{gone.join(', ')}." if gone.any?
      end
    end

    module_function

    # Measure every example against the working tree's library — the same path
    # `rake emitted` measures with, so a recorded number is the number it reports.
    def current
      Emitted.measure(File.join(ROOT, "lib"), Emitted.examples)
    end

    def sizes(measurements)
      measurements.select { |_, m| m.ok? }
                  .sort.to_h { |name, m| [name, { code: m.code, data: m.data }] }
    end

    def errors(measurements)
      measurements.reject { |_, m| m.ok? }.transform_values(&:error)
    end

    def record(out: $stdout, path: PATH)
      measurements = current
      failed = errors(measurements)
      failed.each { |name, message| out.puts "#{name} does not build: #{message}" }
      return false if failed.any?

      before = read(path)
      recorded = sizes(measurements)
      write(path, recorded)
      Verdict.new(recorded: before, measured: recorded).render(out) if before.any?
      out.puts "Recorded #{recorded.size} examples in #{Emitted.relative(path)}."
      true
    end

    def check(out: $stdout, path: PATH)
      recorded = read(path)
      if recorded.empty?
        out.puts "There is no baseline at #{Emitted.relative(path)}. Write one with:"
        out.puts "  #{ACCEPT}"
        return false
      end

      measurements = current
      verdict = Verdict.new(recorded: recorded, measured: sizes(measurements),
                            errors: errors(measurements))
      verdict.render(out)
      verdict.ok?
    end

    # Example names stay strings, matching what #sizes measures — symbolising the
    # whole document would rename every example and make each one look brand new.
    def read(path = PATH)
      data = JSON.parse(File.read(path))
      (data["examples"] || {}).transform_values { |e| { code: e["code"], data: e["data"] } }
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    # Sorted and pretty-printed so its diff is readable in a review — that diff is
    # the whole reason the file is checked in.
    def write(path, recorded)
      payload = { version: VERSION, examples: recorded.sort.to_h }
      File.write(path, "#{JSON.pretty_generate(payload)}\n")
    end
  end

  module_function

  def relative(path) = path.to_s.delete_prefix("#{ROOT}/")
end
