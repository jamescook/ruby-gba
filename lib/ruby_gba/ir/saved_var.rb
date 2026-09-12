# frozen_string_literal: true

module RubyGBA
  module IR
    # A VARIABLE THAT SURVIVES POWER-OFF — a high score, an unlock, a setting — as the three
    # facts every backend needs about one: what it is called, what it holds on a cartridge
    # nobody has played yet, and which place in save memory is its.
    #
    # It travels further than anything else the framework builds: declared by `save_var` in the
    # Builder, carried in a `save_init` node's operands, and read by BOTH backends. So it is the
    # backends' shared contract about saving, and it lives here — in the IR, which is the tree
    # whose whole job is to be the thing they agree about — rather than in either of them.
    #
    # +slot+ is counted from 0 in declaration order, and what a slot MEANS is the backend's
    # business: the console turns it into a byte offset into the cartridge's save memory, and
    # the interpreter uses it as a key into a fake one. Nothing here says a word about SRAM.
    SavedVar = Data.define(:name, :default, :slot)
  end
end
