# frozen_string_literal: true

require_relative "../lib/ruby_gba"

# The cross-backend conformance fixture: ONE synthetic IR program that exercises
# (nearly) every supported IR feature — not a game, a kitchen sink. It exists so
# a backend can't silently lag: run it through every backend and an unimplemented
# feature hits that backend's "unsupported" branch and fails the test.
#
# MAINTENANCE OBLIGATION: when you add a new IR feature (a node kind or a binop
# operator), add it here. The coverage test asserts this fixture touches every
# kind in Node::CATEGORY and every operator in OPERATORS, so a forgotten feature
# fails loudly. See the cross-backend rule in .claude/CLAUDE.md.
#
# The lone exception is `raw` — pre-assembled native bytes, which the portable
# interpreter legitimately can't run (there's no ARM CPU behind it). It lives in
# an UNCALLED func here: present in the tree (so the GBA backend lowers it and
# coverage sees it), but never reached during interpretation. Formal
# portable-vs-hardware-only tagging is gba-4l2; until then HARDWARE_ONLY_KINDS
# encodes the one exemption.
module ConformanceFixture
  B = RubyGBA::IR::Build

  # Every binary operator the backends implement (arithmetic, comparison, and the
  # 0/1 logical composition `held(:a) & held(:b)` lowers to). Kept in sync with
  # each backend's binop dispatch by the coverage test.
  OPERATORS = %i[+ - * / == != < > <= >= and or].freeze

  # Node kinds a portable backend may legitimately not implement (see the module
  # note). Everything else must run on every backend.
  HARDWARE_ONLY_KINDS = %i[raw].freeze

  # Build the fixture fresh each call (nodes carry parent links, so callers get
  # their own tree). Structured so the interpreter, running top to bottom, reaches
  # every portable feature before halting.
  def self.program
    B.program(
      # --- executed setup: turn the screen and sound on ---
      B.display(:bitmap),
      B.enable_sound,

      # --- definitions: registered up front, referenced by name below ---
      B.define_sound(:blip, frequency: 880),
      B.song(:tune, events: [[0, 440], [4, 0]], total_frames: 8),
      B.data(:blob, "\x01\x02\x03\x04".b),
      B.bitmap(:sprite, width: 2, height: 2,
                        pixels: [0x001F, 0x03E0, 0x7C00, 0x8000].pack("v*"),
                        transparent: 0x8000),
      B.func(:helper, B.set(:h, 1), B.add(:h, 2), B.wait_vblank),
      B.func(:scene_a, B.set(:picked, 10)),
      B.func(:scene_b, B.set(:picked, 20)),
      # Uncalled: the GBA backend still lowers its `raw`, but the interpreter never
      # reaches it (raw is hardware-only). This is what keeps `raw` in coverage
      # without breaking the portable run.
      B.func(:hardware_only, B.raw([0xE1A00000].pack("V"))), # a single ARM NOP

      # --- variable ops ---
      B.set(:x, 5), B.add(:x, 3), B.sub(:x, 1), B.copy(:y, :x),
      B.negate(:y), B.abs(:y), B.negate_abs(:y), B.clamp(:y, 0, 100),

      # --- every value-operand kind and every operator ---
      *OPERATORS.map { |op| B.set(:acc, B.binop(op, B.var_ref(:x), B.int(2))) },
      B.set(:acc, B.neg(B.var_ref(:x))),      # neg
      B.set(:acc, B.data_byte(:blob, 0)),     # data_byte reads embedded data
      B.set(:acc, B.held(:a)),                # held (button read)
      B.set(:acc, B.pressed(:b)),             # pressed (edge read)

      # --- every drawing op ---
      B.clear_screen(:black),
      B.pixel(1, 1, :red),
      B.fill_rect(2, 2, 4, 4, :green),
      B.dma_fill_rect(8, 8, 4, 4, :blue),
      B.draw_rect_at(:x, :y, 4, 4, :white),
      B.draw_text("HI", 10, 10, :white),
      B.blit(:sprite, :x, :y),

      # --- every sound trigger ---
      B.beep(:blip),
      B.play_song(:tune),
      B.stop_music,

      # --- control flow: if+else, call, case ---
      if_else,
      B.call(:helper),
      B.set(:sel, 0),
      B.case_(:sel, { 0 => :scene_a, 1 => :scene_b }),

      # --- terminate: a loop that syncs once then halts (covers loop + halt) ---
      B.loop_(B.wait_vblank, B.halt),
    )
  end

  # An `if` carrying an `else`. Built in two steps because the else lives in the
  # if node's :else attr (that's how the DSL attaches a trailing `.else`).
  def self.if_else
    branch = B.if_(B.binop(:>, B.var_ref(:x), B.int(0)), B.set(:acc, 1))
    branch[:else] = B.else_(B.set(:acc, 2))
    branch
  end
end
