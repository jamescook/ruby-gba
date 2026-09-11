# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# THE EMULATOR, FOR DEVELOPING THIS LIBRARY — not for using it.
#
# Here rather than in the gemspec on purpose. Building and shipping a cartridge is pure Ruby;
# putting it in the gemspec would make everyone who installs ruby-gba need a C compiler and
# libmgba whether or not they ever run a ROM. Working ON this library does need one, because
# the suite reads real pixels off a real emulator.
#
# WHAT THIS LINE DOES AND DOES NOT DO. It puts the emulator on the load path, so
# `require "ruby_gba_emulator"` resolves and RubyGBA::Emulator takes the same route a consumer
# takes rather than its sibling-checkout fallback — which is the point of declaring it, since a
# fallback nobody else has is a fallback that hides whether the normal path works.
#
# It does NOT build the C extension. Bundler compiles extensions for gem and git sources but
# not for a `path:` source, which it treats as a gem you are developing and expects to be built
# already. So `rake compile_emulator` builds it (every test task depends on that), and a bare
# `bundle install` leaves you with a gem that resolves and will not load.
#
# The consequence worth knowing: that build is keyed on source files being newer, which cannot
# see a change of RUBY VERSION — a compiled extension is tied to the Ruby that built it, and
# switching Ruby makes nothing newer. After switching Ruby, run `rake clean` in
# ruby-gba-emulator/. A GAME never meets this, because it takes the emulator from git, where
# bundler installs extensions per Ruby ABI. One block for both gems, since both live in this
# one repository — two `gem ... github:` lines are two sources cloning into one directory,
# which races and fails:
#
#   git "https://github.com/jamescook/ruby-gba.git",
#       glob: "{,ruby-gba-emulator/}*.gemspec" do
#     gem "ruby-gba"
#     gem "ruby-gba-emulator"
#   end
gem "ruby-gba-emulator", path: "ruby-gba-emulator"
