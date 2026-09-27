# frozen_string_literal: true

module RubyGBA
  module IR
    # Portability tiers: which IR node kinds a non-GBA backend can lower, and which
    # are GBA-only escape hatches.
    #
    # The IR is meant to be target-neutral, but not every node can be. Most describe
    # *what the program does* in terms any backend understands — set a variable, add
    # two numbers, fill a rectangle, play a tone — so a web/canvas or terminal
    # backend could realize them natively. A few are opaque hardware: +raw+ is
    # pre-assembled ARM bytes that only a native backend can place, and that even
    # the GBA backend can't explain, simulate, or translate.
    #
    # So each kind is tagged +:portable+ or +:hardware_only+. A whole program's tier
    # is the *floor* over its nodes — one hardware-only node makes the program
    # hardware-only — and a backend declares the tier it accepts (the GBA and
    # reference backends take everything; a future web backend would take
    # portable-only). That
    # lets a preflight say, once and up front, "this program uses `raw`, which only
    # runs on :gba," instead of exploding partway through lowering. This module is
    # the classification and the queries over it; the lint that reports a mismatch
    # to the developer is a separate pass built on top.
    #
    # The tag is per-*kind*, deliberately coarse: it answers "could any backend
    # lower this kind of op?", not "is this particular use portable?" (a raw
    # register value passed to a portable node is a finer question for another day).
    #
    # North star: +raw+ should be the only lasting hardware-only kind. Every other
    # reach for it is a missing IR node — grow a real one that every backend lowers,
    # rather than making +raw+ portable (it can't be; it's opaque).
    module Portability
      module_function

      # The tiers, worst-first: a program's tier is the floor over its nodes, so
      # +:hardware_only+ dominates +:portable+.
      TIERS = %i[hardware_only portable].freeze

      # Every kind's tier, read off the kind's own declaration (see Node::Declarations#tier)
      # rather than listed here. A kind is portable unless it says otherwise, where it is
      # declared, and that is not a promise made by default: every portable kind has to be one
      # the interpreter runs and the console lowers, which a coverage test holds them to — so a
      # new kind neither backend can run fails there until it is given handlers or says it is
      # hardware-only.
      TIER = Ractor.make_shareable(Nodes.by_kind.transform_values(&:tier))

      # The tier of a kind (a Symbol) or a Node. Raises on a name that is no kind.
      def of(node_or_kind)
        kind = node_or_kind.is_a?(Node) ? node_or_kind.kind : node_or_kind
        TIER.fetch(kind) do
          raise ArgumentError,
                "no IR kind #{kind.inspect}, so it has no portability tier"
        end
      end

      def portable?(node_or_kind)
        of(node_or_kind) == :portable
      end

      def hardware_only?(node_or_kind)
        of(node_or_kind) == :hardware_only
      end

      # Every kind tagged hardware-only across the whole taxonomy — the set a
      # portable backend may legitimately not implement. What the conformance guard
      # reads for its exemptions.
      def hardware_only_kinds
        TIER.filter_map { |kind, tier| kind if tier == :hardware_only }
      end

      # A program's tier: the floor over its nodes. Portable only if every node is.
      def program_tier(program)
        program.walk.any? { |node| hardware_only?(node) } ? :hardware_only : :portable
      end

      # The distinct hardware-only kinds a program actually uses — the data a lint
      # needs to tell the developer which ops keep it off a portable backend.
      def hardware_only_kinds_in(program)
        program.walk.map(&:kind).uniq.select { |kind| hardware_only?(kind) }
      end
    end
  end
end
