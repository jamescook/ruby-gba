# frozen_string_literal: true

require_relative "backends/reference"
require_relative "backends/gba"

module RubyGBA
  module IR
    # Backends consume an IR tree; the IR itself (Node / Build / Int32) knows
    # nothing about any of them. A backend either *interprets* the tree
    # (Backends::Reference runs it here; a JS backend would run it in a browser) or
    # *lowers* it (Backends::GBA compiles it to a ROM). Every backend is
    # downstream of the IR and must honor its reference semantics (IR::Int32) —
    # that shared contract is what lets them agree.
    #
    # Naming: a backend that targets a real platform is named for that *platform*,
    # not the mechanism — so the ROM backend is `GBA` (ARM CPU + GBA hardware +
    # cart format), not `Arm`.
    #
    # `Reference` is deliberately not named that way, because it isn't a platform
    # anyone ships to. It's the answer key: the implementation that defines what a
    # program means, which the others are checked against. Naming it for its role
    # rather than for the language it happens to be written in also keeps it from
    # reading as "the Ruby one" in a project where every backend is written in Ruby.
    module Backends
    end
  end
end
