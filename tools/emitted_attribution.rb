# frozen_string_literal: true

# Which emitted bytes came from which part of the program.
#
# `rake emitted` says a ROM grew by 126 instructions. This says where they went:
# which funcs, which lines of the game, and which kinds of operation.
#
# THE AXIS THAT EXPLAINS IS BYTES PER KIND, and it is worth saying why, because
# counting the operations in the tree looks like the obvious thing and is nearly
# useless. Both sides build the same example file, so a change to the LOWERING
# leaves the tree identical — same operations, same number of them — and only the
# bytes each one turns into move. Counting nodes would report "no change" for
# precisely the changes this tool exists to explain. Counting the BYTES each kind
# of operation produced reports "clamp: 296 to 368 across 8 sites", which is the
# answer.
#
# Bytes are attributed EXCLUSIVELY: a loop is charged for the loop's own
# bookkeeping, not for its body, so the numbers down a column add up instead of
# counting the same byte at every level of nesting.
#
# THE BUILD COUNTS THIS FOR ITSELF NOW — see IR::Backends::GBA::Attribution, which
# every build fills in because the estimate prices a statement by what it emitted.
# So today's library is asked rather than watched, and what is left here is the
# reduction: bytes per func, per kind, per line of the game.
#
# The watching stays for one reason, and it is the rule this whole tool is built
# around (see tools/emitted_probe.rb): it measures with whatever the library at the
# other end already offers, so that it can run against an OLD commit. A library from
# before the build counted anything cannot be asked, and #Recorder is how it is
# measured anyway.
module EmittedAttribution
  # Remembers, for every statement lowered, how many bytes that statement alone
  # produced. Prepended to a throwaway subclass rather than to the backend itself,
  # so a process that measures one build is not changed for everything else it does.
  #
  # Every statement passes through one place — GBA::Lowering#statement, not a method
  # on the backend itself — so this wraps that one method on the backend's own
  # Lowering instance (built fresh in its own #initialize, then reached here) rather
  # than prepending an override the backend would call.
  module Recorder
    def attributed = @attributed ||= []
    def attribution_depth = @attribution_depth ||= []

    def initialize(...)
      super
      backend = self
      original = lowering.method(:statement)
      lowering.define_singleton_method(:statement) do |node|
        depth = backend.attribution_depth
        start = backend.send(:pos)
        depth.push(0) # bytes my own nested statements will claim
        result = original.call(node)
        inner = depth.pop
        mine = backend.send(:pos) - start
        depth[-1] += mine unless depth.empty? # tell whoever contains me what I took
        backend.attributed << [node, mine - inner]
        result
      end
    end
  end

  # What one build produced, broken down. +total+ is every byte the backend
  # emitted; the three maps each account for part of it.
  Breakdown = Data.define(:total, :funcs, :kinds, :lines, :unattributed)

  module_function

  # A backend that has to be watched, or the plain one when it counts for itself.
  def recording(backend_class)
    return backend_class if counts_itself?(backend_class)

    Class.new(backend_class) { prepend Recorder }
  end

  # Whether this library's build already records what each node emitted.
  def counts_itself?(backend_class)
    backend_class.method_defined?(:attribution)
  end

  # Lower +program+ and report where its bytes came from.
  def measure(backend_class, program)
    backend = recording(backend_class).new
    code = backend.lower(program)
    breakdown(backend, code.bytesize)
  end

  # The same report, for a caller that already has a backend it lowered with — the
  # probe needs the backend for other reasons too.
  def breakdown(backend, total)
    rows = rows_for(backend)

    Breakdown.new(
      total: total,
      # Funcs come from the backend's own span table, which is exact and covers the
      # whole body of each one — including anything the lowering added around it.
      funcs: backend.func_ranges.transform_values(&:size),
      kinds: sum_by(rows) { |node, _| node.kind.to_s },
      # A node knows the line of the game that asked for it. Framework-made nodes
      # (a hidden counter, a frame sync written for you) have no call site of their
      # own and are grouped together rather than dropped.
      lines: sum_by(rows) { |node, _| node.source || "(framework)" },
      # Boot code, the data region, the interrupt handler: emitted by the backend
      # around the program rather than by any statement in it. Named so the columns
      # can be seen not to add up to the whole, instead of quietly not adding up.
      unattributed: total - rows.sum { |_, bytes| bytes },
    )
  end

  # Node and bytes, whichever way this build was measured. The library's own answer is
  # instructions per node, totalled over every place the node was lowered from — the same
  # bytes #Recorder collects one place at a time, so the two reduce identically.
  def rows_for(backend)
    return backend.attributed unless counts_itself?(backend.class)

    backend.attribution.emitted.map { |node, e| [node, e.instructions * INSTRUCTION_BYTES] }
  end

  INSTRUCTION_BYTES = 4

  def sum_by(rows)
    totals = Hash.new(0)
    rows.each { |node, bytes| totals[yield(node, bytes)] += bytes }
    totals.reject { |_, bytes| bytes.zero? }.sort_by { |key, bytes| [-bytes, key] }.to_h
  end
end
