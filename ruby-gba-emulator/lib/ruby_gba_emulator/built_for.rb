# frozen_string_literal: true

require "rbconfig"

module RubyGBAEmulator
  # WHICH RUBY A BUILT EXTENSION BELONGS TO, as a directory name.
  #
  # A compiled extension is tied to the Ruby that built it, down to the patch release — a
  # version manager keeps each one under a prefix of its own, and the binary names that
  # prefix's libruby, so a Ruby that did not build it refuses to load it. Naming the Ruby and
  # the architecture in the path is what makes that visible to a build: a Ruby with no
  # directory of its own has nothing to load and compiles one, where a single shared path looks
  # up to date to `make` and to rake alike and hands over a binary that cannot run.
  #
  # It keeps both, so moving between two Rubies is free rather than a recompile each way.
  #
  # A gem install never sees this. RubyGems builds the extension itself, per ABI, and puts it
  # on a load path of its own.
  BUILT_FOR = "#{RUBY_VERSION}-#{RbConfig::CONFIG['arch']}"
end
