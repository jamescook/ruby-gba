# frozen_string_literal: true

require_relative "ir/int32"
require_relative "ir/buttons"
require_relative "ir/screen"
require_relative "ir/frames" # how many frames a pass of the game loop took
require_relative "ir/node"  # what every node can do; names no kind
require_relative "ir/nodes" # one class per kind, each declaring its own operands
require_relative "ir/fields" # the operand tables, read off the classes
require_relative "ir/assets" # what a declared image or recording is, for every backend
require_relative "ir/saved_var" # ...and what a variable that survives power-off is
require_relative "ir/tile_map" # how big a grid a background scrolls over, for every backend
require_relative "ir/build"
require_relative "ir/parity"
require_relative "ir/affine"
require_relative "ir/modes"
require_relative "ir/stacking" # the one rule turning declared layers into a drawing order
require_relative "ir/tunes" # which tunes a program plays, and the mixer voices they keep
require_relative "ir/verifier"
require_relative "ir/portability"
require_relative "ir/backends"
require_relative "ir/guardrails"
require_relative "ir/printer" # what a report is written through
require_relative "ir/glyph_usage"
require_relative "ir/palette"
require_relative "ir/dump"

module RubyGBA
  # The intermediate representation (IR): the plain-Ruby op-tree the DSL builds
  # instead of emitting target code directly.
  #
  # The DSL constructs an {IR::Node} tree (see {IR::Build} for readable
  # constructors); a validation pass then walks it to catch footguns *before*
  # any code exists, and a lowering pass turns it into code for a concrete
  # target. Keeping the program as inspectable data — rather than output emitted
  # on the fly — is what makes those passes, and forward references, possible.
  #
  # The IR is deliberately target-agnostic: it describes *what the program does*,
  # not how one machine runs it. ARM/GBA is the current lowering backend, but
  # nothing here assumes it — another backend (e.g. JavaScript) could lower the
  # same tree. Target-specific detail belongs in the lowering pass, not here.
  module IR
  end
end
