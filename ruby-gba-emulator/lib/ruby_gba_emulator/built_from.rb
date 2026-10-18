# frozen_string_literal: true

require "digest"

module RubyGBAEmulator
  # WHICH SOURCE A BUILT EXTENSION CAME FROM, so a checkout can tell a build that is out of date.
  #
  # In a checkout the two halves of this gem move apart. The Ruby half is read from the files
  # every time it loads, so pulling new code changes it at once; the compiled half is whatever
  # was last built, and stays that way until somebody builds again. When the new Ruby asks the
  # old build for something it does not hand back yet, nothing says so — a value is simply
  # missing, and the error surfaces as a NoMethodError several calls away from the cause.
  #
  # So extconf.rb works out a fingerprint of the C source and compiles it into the extension as
  # BUILT_FROM, and the entry point compares it with the source beside it as it loads. A gem
  # install is never checked: RubyGems builds it from the very source it installs, and nothing
  # pulls new code into it afterwards.
  SOURCE_DIR = File.expand_path("../../ext/ruby_gba_emulator_ext", __dir__)

  # Raised when the build loaded is not from the source beside it. Not a LoadError: the
  # extension did load, and a caller that treats "no emulator" as "carry on without one" has to
  # hear this one rather than quietly measure nothing.
  class OutOfDate < StandardError; end

  class << self
    # A fingerprint of the C source in +dir+: its .c and .h files, by name and content. What a
    # build leaves beside them — the Makefile, the object files — is not source and not counted.
    def source_fingerprint(dir = SOURCE_DIR)
      digest = Digest::SHA256.new
      Dir.glob("*.{c,h}", base: dir).sort.each do |name|
        digest << name << "\0" << File.binread(File.join(dir, name)) << "\0"
      end
      digest.hexdigest
    end

    # Raise OutOfDate unless +built_from+ is the fingerprint of the source in +source_dir+. A
    # build from before builds carried a fingerprint has none, and is out of date by definition.
    def refuse_out_of_date_build!(built_from: (BUILT_FROM if const_defined?(:BUILT_FROM)),
                                  source_dir: SOURCE_DIR)
      return if built_from == source_fingerprint(source_dir)

      raise OutOfDate, <<~MSG
        The ruby-gba-emulator extension is out of date. It was built from different C source than the source in #{source_dir}, and the Ruby half of the gem cannot use it.
        To rebuild the extension, run `rake compile` in #{File.expand_path("../..", source_dir)}.
      MSG
    end
  end
end
