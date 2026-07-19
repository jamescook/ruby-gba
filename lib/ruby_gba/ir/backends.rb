# frozen_string_literal: true

require_relative "backends/ruby"
require_relative "backends/gba"

module RubyGBA
  module IR
    # Backends consume an IR tree; the IR itself (Node / Build / Int32) knows
    # nothing about any of them. A backend either *interprets* the tree
    # (Backends::Ruby runs it in Ruby; a JS backend would run it in a browser) or
    # *lowers* it (a GBA backend compiles it to a ROM). Every backend is
    # downstream of the IR and must honor its reference semantics (IR::Int32) —
    # that shared contract is what lets them agree.
    #
    # Naming: backends are named for the *platform they target*, not the
    # mechanism — so the ROM backend is `GBA` (ARM CPU + GBA hardware + cart
    # format), not `Arm`.
    module Backends
    end
  end
end
