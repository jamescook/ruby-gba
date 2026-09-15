# frozen_string_literal: true

module RubyGBA
  # Where a build prints: the warnings the guardrails found, and the disassembly
  # `dump_func` was asked for. `out:` and `err:` each take one of three things, because all
  # three are reasonable readings of "where does this go" — an open stream, the NAME of a
  # file, or nothing at all from a caller that wants the build quiet. This turns whichever
  # arrived into one thing the build can print to, so nothing downstream has to ask.
  #
  # The name is the case worth explaining. `File::NULL` IS a name — the string "/dev/null" —
  # so "build quietly" gets written as a path more often than as anything else, and a path
  # that worked only until the build had a warning to give would fail at the worst possible
  # moment: the build that finally has something to say would be the build that cannot say
  # it. A path is opened here and closed when the build ends, so a caller that passes one
  # never has a file handle of its own to look after.
  class BuildOutput
    # Everything written here goes nowhere, which is what `nil` asks for. An object of our
    # own rather than the machine's null device, so a quiet build opens no file at all.
    class Quiet
      def puts(*) = nil
      def write(*) = 0
      def print(*) = nil
      def flush = self
      def tty? = false
    end

    QUIET = Quiet.new

    attr_reader :out, :err

    def initialize(out:, err:)
      @opened = []
      @out = writable(out)
      @err = writable(err)
    rescue StandardError
      # One of the two could not be opened after the other already was — a path into a
      # directory that is not there. Give the handle back before the error goes up, or a
      # caller that rescues it leaks a file per attempt.
      close
      raise
    end

    # Close what was opened here and nothing else. A stream the caller handed over already
    # open stays open — it is the caller's, and a build that runs twice to measure itself
    # (see {RubyGBA.build_measured}) hands the inner builds the stream the outer one opened.
    def close
      @opened.each(&:close)
      @opened = []
      self
    end

    private

    # In this order, because a File answers to both of the first two: anything that can
    # already be printed to is left alone, and only then is a name treated as a name.
    # Anything else is handed straight on and trusted to behave like a stream.
    def writable(given)
      return QUIET if given.nil?
      return given if given.respond_to?(:puts)
      return opened_at(given.to_path) if given.respond_to?(:to_path)
      return opened_at(given) if given.is_a?(String)

      given
    end

    def opened_at(path)
      file = File.open(path, "w")
      @opened << file
      file
    end
  end
end
