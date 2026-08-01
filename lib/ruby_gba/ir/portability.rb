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
    # hardware-only — and a backend declares the tier it accepts (the GBA and Ruby
    # backends take everything; a future web backend would take portable-only). That
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

      # Every kind's tier — the single source of truth, coverage-locked against
      # Node::CATEGORY so a new kind can't be added without a conscious choice.
      # Grouped to mirror CATEGORY. Today only +raw+ is hardware-only; the framebuffer
      # draws, text, and PSG sound are all portable (a canvas / web-audio backend can
      # realize them), as are vars, arithmetic, control flow, lists, and embedded data.
      TIER = {
        program: :portable,

        # variable operations
        set: :portable, add: :portable, sub: :portable, copy: :portable,
        negate: :portable, abs: :portable, negate_abs: :portable, clamp: :portable,
        # persistence — remembering values across power-off. Portable intent: the
        # interpreter models it against an in-memory save store, the GBA lowers it to
        # battery-backed save memory, a web backend could use localStorage.
        save_init: :portable, save_store: :portable,

        # drawing / screen — framebuffer draws and text are portable; `screen`
        # selects a rendering model a backend can honor (the raw-register form and
        # GBA-only modes like affine are a per-argument nuance for when a web backend
        # exists to care — a per-kind tag can't express them).
        screen: :portable, pixel: :portable, fill_rect: :portable, clear_screen: :portable,
        draw_rect_at: :portable, draw_text: :portable, dma_fill_rect: :portable, blit: :portable,
        draw_digit: :portable, # index a font by a run-time digit — any backend can
        blit_pose: :portable,  # pick one of a set of images by a run-time index — any backend can
        background: :portable, # stamp a grid of tiles — pixels or tile hardware, any backend can
        scroll_background: :portable, # move the window over a map — re-render or nudge scroll regs
        # a composited moving picture — software compositing or sprite hardware, any backend can
        object: :portable, present_objects: :portable,
        # save/restore a screen patch — copying pixels to/from a buffer, any backend can
        save_region: :portable, restore_region: :portable,

        # audio — square-wave PSG, noise, and wavetables a web-audio backend can synthesize
        enable_sound: :portable, define_sound: :portable, beep: :portable, noise: :portable,
        wave: :portable, stop_wave: :portable,
        song: :portable, play_song: :portable, stop_music: :portable,
        # sampled PCM audio — recorded sound any backend with a mixer can play back
        play_sample: :portable, stop_sample: :portable,

        # control flow
        if: :portable, else: :portable, loop: :portable, repeat: :portable,
        func: :portable, call: :portable, case: :portable, wait_vblank: :portable, halt: :portable,
        every: :portable, after: :portable, # timed triggers: plain counter logic any backend can run
        # hardware timers: the node carries a rate in Hz (portable intent) — a backend
        # realizes it however it likes (GBA timer registers, or a frame-clock model).
        # on_timer's handler body runs once per overflow — plain repetition any backend models.
        timer_start: :portable, timer_stop: :portable, on_timer: :portable,

        # the opaque escape hatch — pre-assembled native bytes no backend can model
        raw: :hardware_only,

        # reading the live scanline (VCOUNT): only a real console is drawing one, so
        # the headless interpreter (which has no real timing) can't model it
        read_scanline: :hardware_only,

        # embedded data
        data: :portable, bitmap: :portable, backing_buffer: :portable,
        sample: :portable, # embedded 8-bit PCM sound data

        # lists
        list_new: :portable, list_push: :portable, list_drop: :portable, list_set: :portable,

        # expression values
        int: :portable, var_ref: :portable, binop: :portable, neg: :portable,
        data_byte: :portable, list_get: :portable, list_len: :portable,
        timer_ticks: :portable, # elapsed timer overflows — a plain counter any backend can model
        held: :portable, pressed: :portable,
        chance: :portable, # a random draw compared to a threshold — plain arithmetic
        pixels_overlap: :portable, # reads each sprite's picture; any backend with the images can test it
      }.freeze

      # The tier of a kind (a Symbol) or a Node. Raises on an unclassified kind —
      # a new primitive with no tag is drift, caught here rather than silently
      # assumed portable (which would falsely promise it runs on the web).
      def of(node_or_kind)
        kind = node_or_kind.is_a?(Node) ? node_or_kind.kind : node_or_kind
        TIER.fetch(kind) do
          raise ArgumentError,
                "no portability tag for IR kind #{kind.inspect} — add it to Portability::TIER " \
                "(:portable or :hardware_only)"
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
