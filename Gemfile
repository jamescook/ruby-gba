# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The emulator, ruby-gba-emulator, is deliberately NOT here.
#
# Two reasons, and they point the same way. It is not in the gemspec because building and
# shipping a cartridge is pure Ruby — putting it there would make everyone who installs
# ruby-gba need a C compiler and libmgba whether or not they ever run a ROM. And it is not a
# `path:` entry here either, because bundler does not compile extensions for a path source: it
# treats one as a gem you are developing and expects the build to exist already, so the line
# would look like it maintained the extension while doing nothing of the kind.
#
# This repository uses the checkout in ruby-gba-emulator/, kept built by
# `rake compile_emulator`. That rebuilds when a SOURCE changes, which cannot see a Ruby version
# change — after switching Ruby, run `rake clean` in ruby-gba-emulator/.
#
# A GAME depending on ruby-gba takes it through bundler instead, where extensions are installed
# per Ruby ABI and none of this applies:
#
#   gem "ruby-gba-emulator", github: "jamescook/ruby-gba",
#       glob: "ruby-gba-emulator/ruby-gba-emulator.gemspec"
