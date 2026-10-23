# frozen_string_literal: true

module RubyGBA
  module Testing
    # HOW FAR A RUN HAS GOT, as a line of its own every hundred tests, for a log nobody watches
    # in a terminal.
    #
    # Minitest prints a dot for each test played, all on one line. A terminal shows the dots as
    # they come; a CI log shows a line only once it ends, and that line ends with the run, so a
    # run of a quarter of an hour says nothing at all until it is over. A line every hundred
    # tests ends that line regularly. The dots carry on on the line below.
    #
    # Added to a run only when the CI setting is there (see testing.rb), so a run in a terminal
    # keeps its one unbroken line of dots. Loading this file adds nothing to a run by itself.
    class ProgressLines < Minitest::AbstractReporter
      EVERY = 100

      def initialize(io, total:)
        super()
        @io = io
        @total = total
        @played = 0
      end

      def record(_result)
        @played += 1
        @io.print "\n#{@played} of #{@total} tests played\n" if (@played % EVERY).zero?
      end

      # One for the run minitest is about to play. The total is the tests it will play once its
      # filters are applied, worked out here because a reporter is told about each test as it
      # finishes and never how many there are.
      def self.for_run(options)
        total = Minitest::Runnable.runnables.sum { |klass| klass.filter_runnable_methods(options).size }
        new(options[:io], total: total)
      end
    end
  end
end
