# frozen_string_literal: true

require_relative "ir/node"
require_relative "ir/build"

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
