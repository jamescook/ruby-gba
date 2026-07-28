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
# coverage sees it), but never reached during interpretation. Which kinds are
# exempt comes straight from the portability tags (Portability::TIER), the single
# source of truth — not a list hardcoded here.
module ConformanceFixture
  B = RubyGBA::IR::Build

  # Every binary operator the backends implement (arithmetic, comparison, and the
  # 0/1 logical composition `held(:a) & held(:b)` lowers to). Kept in sync with
  # each backend's binop dispatch by the coverage test.
  OPERATORS = %i[+ - * / == != < > <= >= and or].freeze

  # Node kinds a portable backend may legitimately not implement — the kinds tagged
  # hardware-only, read from the portability classification rather than restated.
  HARDWARE_ONLY_KINDS = RubyGBA::IR::Portability.hardware_only_kinds.freeze

  # Build the fixture fresh each call (nodes carry parent links, so callers get
  # their own tree). Structured so the interpreter, running top to bottom, reaches
  # every portable feature before halting.
  def self.program
    B.program(
      # --- executed setup: turn the screen and sound on ---
      B.screen(:bitmap),
      B.enable_sound,

      # --- definitions: registered up front, referenced by name below ---
      B.define_sound(:blip, frequency: 880),
      B.song(:tune, events: [[0, 440], [4, 0]], total_frames: 8),
      B.data(:blob, "\x01\x02\x03\x04".b),
      B.bitmap(:sprite, width: 2, height: 2,
                        pixels: [0x001F, 0x03E0, 0x7C00, 0x8000].pack("v*"),
                        transparent: 0x8000),
      B.bitmap(:pose_b, width: 2, height: 2, # a second same-size pose, for blit_pose
                        pixels: [0x7C00, 0x03E0, 0x001F, 0x7FFF].pack("v*"), transparent: nil),
      B.bitmap(:tile_a, width: 2, height: 2, # two opaque tiles, for the background grid
                        pixels: [0x001F, 0x001F, 0x001F, 0x001F].pack("v*"), transparent: nil),
      B.bitmap(:tile_b, width: 2, height: 2,
                        pixels: [0x03E0, 0x03E0, 0x03E0, 0x03E0].pack("v*"), transparent: nil),
      B.bitmap(:obj8, width: 8, height: 8, # an 8x8 picture for a composited object (a valid sprite size)
                       pixels: Array.new(64, 0x03E0).pack("v*"), transparent: nil),
      B.backing_buffer(:under, width: 4, height: 4), # a save-under patch for a moving object
      B.func(:helper, B.set(:h, 1), B.add(:h, 2), B.wait_vblank),
      B.func(:scene_a, B.set(:picked, 10)),
      B.func(:scene_b, B.set(:picked, 20)),
      # Uncalled: the GBA backend still lowers these, but the interpreter never
      # reaches them (both are hardware-only). This is what keeps the hardware-only
      # kinds in coverage without breaking the portable run.
      B.func(:hardware_only,
             B.raw([0xE1A00000].pack("V")),   # a single ARM NOP
             B.set(:hw_scanline, B.read_scanline)), # a hardware-only value read (VCOUNT)

      # --- variable ops ---
      B.set(:x, 5), B.add(:x, 3), B.sub(:x, 1), B.copy(:y, :x),
      B.negate(:y), B.abs(:y), B.negate_abs(:y), B.clamp(:y, 0, 100),

      # --- every value-operand kind and every operator ---
      *OPERATORS.map { |op| B.set(:acc, B.binop(op, B.var_ref(:x), B.int(2))) },
      B.set(:acc, B.neg(B.var_ref(:x))),      # neg
      B.set(:acc, B.data_byte(:blob, 0)),     # data_byte reads embedded data
      B.set(:acc, B.held(:a)),                # held (button read)
      B.set(:acc, B.pressed(:b)),             # pressed (edge read)
      B.set(:acc, B.chance(B.var_ref(:x), 50)), # chance (draw-below-threshold read)
      B.set(:acc, B.pixels_overlap(              # per-pixel sprite collision (two posed sprites)
              a_poses: [:sprite, :pose_b], a_pose: B.int(0), a_x: B.int(0), a_y: B.int(0),
              b_poses: [:sprite, :pose_b], b_pose: B.int(1), b_x: B.int(1), b_y: B.int(1))),

      # --- every drawing op ---
      B.clear_screen(:black),
      B.pixel(1, 1, :red),
      B.fill_rect(2, 2, 4, 4, :green),
      B.dma_fill_rect(8, 8, 4, 4, :blue),
      B.draw_rect_at(:x, :y, 4, 4, :white),
      B.draw_text("HI", 10, 10, :white),
      B.draw_digit(B.var_ref(:x), 20, 10, :white), # one run-time digit glyph
      B.blit(:sprite, :x, :y),
      B.blit_pose([:sprite, :pose_b], B.var_ref(:x), :x, :y), # one pose of a same-size set, by index
      B.background(:grid, tiles: [:tile_a, :tile_b],          # a tiled grid; nil = an empty cell
                          map: [[0, 1], [1, nil]], tile_w: 2, tile_h: 2),
      B.scroll_background(:grid, x: B.var_ref(:x), y: B.var_ref(:y)), # move the window over it
      B.object(:hero_obj, poses: [:obj8], pose: B.int(0), # a composited object (one pose, held at index 0)
                          x: B.var_ref(:x), y: B.var_ref(:y), active: B.int(1)),
      B.present_objects([:hero_obj]),   # draw the declared objects for this frame
      B.save_region(:under, :x, :y),    # remember the pixels under a moving object
      B.restore_region(:under, :x, :y), # then paint them back

      # --- every sound trigger ---
      B.beep(:blip),
      B.noise(:explosion),
      B.wave(shape: :sine, frequency: 440, volume: :full),
      B.stop_wave,
      B.play_song(:tune),
      B.stop_music,

      # --- a list: create, push (constant and computed), overwrite, read, drop ---
      B.list_new(:trail, 4),
      B.list_push(:trail, 7),
      B.list_push(:trail, B.var_ref(:x)), # push a computed value
      B.list_set(:trail, 0, 9),           # overwrite slot 0
      B.set(:acc, B.list_get(:trail, 0)), # read it back (9)
      B.set(:acc, B.list_len(:trail)),    # length (2)
      B.list_drop(:trail, from: :back),   # pop -> length 1
      B.list_drop(:trail, from: :front),  # shift -> length 0

      # --- control flow: if+else, call, case, repeat ---
      if_else,
      B.call(:helper),
      B.set(:sel, 0),
      B.case_(:sel, { 0 => :scene_a, 1 => :scene_b }),
      B.repeat(3, :ri, B.set(:acc, B.var_ref(:ri))), # counted loop, index 0..2

      # --- timed triggers: a repeating and a one-shot timer (counters cleared
      # up front so the interpreter's schedule is deterministic) ---
      B.set(:every_ctr, 0),
      B.set(:after_ctr, 0),
      B.every(:every_ctr, 2, B.set(:acc, 1)), # fires one frame in two
      B.after(:after_ctr, 3, B.set(:acc, 2)), # fires once, three frames in

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
