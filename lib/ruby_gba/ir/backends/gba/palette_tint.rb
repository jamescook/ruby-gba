# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Tinting a picture that is drawn through a COLOR TABLE.
        #
        # Two of the console's three screens don't store a color in every pixel. A pixel
        # is a small number instead — an index — and the color it shows is looked up in a
        # shared table. That is what leaves room for two whole screens (the tear-free
        # bitmap one) and what lets tiles and sprites share their pictures (the tiled
        # one).
        #
        # It also means the display's own color-mixing unit cannot tint them. That unit
        # blends the picture against the BACKDROP — the color shown where nothing was
        # drawn — and the backdrop is the FIRST ENTRY of the same table every pixel reads
        # from. Putting the tint color there turns every pixel that uses entry 0 (an
        # unpainted screen; a see-through tile) into the tint color at full strength,
        # before any blending happens. Measured on hardware: a black square on a green
        # field went red the moment the backdrop was set, with the blend still at zero.
        #
        # So these screens tint the other way round: move every entry of the table
        # toward the color. Everything visible is drawn from the table, so the whole
        # picture moves at once, scenery and sprites alike, and no pixel of the drawn
        # picture is touched — the picture comes back exactly as drawn when the amount
        # returns to 0, because the originals are still in the cartridge.
        #
        # WHAT IT COSTS, and this is the honest half. It is a blend per table entry, so
        # it is proportional to HOW MANY COLORS THE GAME DECLARED — never to what is on
        # screen. It is also transient: the table only has to be rewritten when the
        # amount (or the color) actually CHANGES, so a tint held steady, and the far more
        # common no-tint-at-all, cost one compare and a branch. #emit_palette_tint is
        # built around that compare.
        #
        # The palette layout — the color table itself, the shared background table, the
        # sprite table's blob/size, and which blobs a tint must keep readable — is settled
        # by several prepare passes that run after this object exists, so it arrives late,
        # through #palette=, rather than as a constructor argument (the same shape
        # Functions#modes= is set in). `drawing:` reaches Drawing for the fade/blend
        # arithmetic it shares with a fade and a see-through layer — GBA builds this
        # object before its own @drawing exists, so it hands in `self` and the call
        # resolves once @drawing does (see gba.rb#initialize).
        class PaletteTint
          include Constants

          # The last tint written into the color table, so a tint that has not moved can
          # be skipped. It packs the color and how far, because both have to match for the
          # table to already be right: (color << 5) | steps. Zero steps means "the table
          # holds the originals", whatever color was asked for — so every un-tinted state
          # is the same state and a game that never tints never rewrites anything.
          TINT_STATE = :__tint_state

          # The two halves of a 15-bit color, chosen so each can be blended with ONE
          # multiply. Red and blue sit five bits apart with green between them, so masking
          # green away leaves two fields far enough apart that multiplying by up to 16
          # cannot make either overflow into the other. Green is then done on its own.
          RB_MASK = 0x7C1F
          G_MASK = 0x03E0

          # A blend counts in sixteenths, so dividing by 16 is a shift of 4.
          BLEND_SHIFT = 4

          # Registers held across the walk. It runs as a whole statement, so every
          # register but the variable-address scratch is free.
          TINT_SRC = 2   # where the originals are being read from (the cartridge)
          TINT_DST = 3   # where the blended entries are being written (the color table)
          TINT_END = 4   # one past the last original, which is what ends the walk
          TINT_KEEP = 5  # how much of the original survives, in sixteenths
          TINT_RB = 6    # the red/blue mask, held rather than rebuilt per entry
          TINT_G = 7     # the green mask, likewise
          TINT_ADD = 8   # the color's own red and blue share — the same for every entry
          TINT_ADD_G = 9 # ...and its green one
          TINT_STEPS = 10 # where the steps wait while the remembered tint is compared

          TINT_COLOR_SHIFT = 5 # the steps (0..16) sit below the color in the state word

          # The palette layout this object reads, handed over once the prepare passes that
          # decide it have all run (see #palette=): the color table a buffered scene draws
          # through, the shared background table, the sprite table's blob and size, and the
          # codec map a tint marks so its tables stay readable in the cartridge.
          Layout = Data.define(:palette, :bg_shared, :obj_palette_blob, :obj_palette_units, :blob_codecs)

          def initialize(emitter:, primitives:, lowering:, drawing:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @drawing = drawing
          end

          attr_writer :modes

          def layout=(value)
            @layout = value
          end

          # Does this program tint a screen that draws through a color table, and does it
          # fade at all? Both answers decide code that is emitted far from the tint
          # itself — whether the tables have to stay readable in the cartridge, whether
          # boot clears the state variable, whether a fade has to lift a tint that may be
          # in force — so they are worked out once, before anything is emitted.
          #
          # A build that never tints a table-drawn screen must come out byte for byte as
          # it did before any of this existed, which is what every flag here is for.
          def prepare_palette_tint(program)
            @program_fades = program.walk.any? { |node| node.kind == :fade }
            @palette_tint = program.walk.any? { |node| node.kind == :tint && palette_screen?(node) }
            keep_tint_originals_readable if @palette_tint
          end

          def palette_tint?
            @palette_tint
          end

          # Is the statement on a screen that draws through a color table? The tear-free
          # bitmap screen and the tiled screen both do; the direct-color screen does not,
          # and tints through the display's blend unit instead (Drawing#emit_tint).
          def palette_screen?(node)
            @modes.mode_at(node) != IR::Modes::DIRECT
          end

          # Mix a color into a picture drawn through a color table.
          #
          # The guard comes first and is the whole reason this is affordable. A game
          # writes `tint :red, hurt` on every pass of its loop, and `hurt` is 0 for almost
          # all of them — so the common frame compares one variable, finds nothing has
          # moved, and jumps over the walk entirely.
          def emit_palette_tint(node)
            # The tint and the fade are one effect: the display can only be told one
            # thing about the whole picture at a time, and the interpreter models the same
            # rule. So asking for a tint puts away whatever fade was in force.
            @emitter.write_reg16(REG_BLDY, 0) if @program_fades

            done = @emitter.gensym
            emit_tint_state(node, done) # r0 = the steps, when the game works them out
            emit_tint_shares(node)
            tint_tables(@modes.mode_at(node)).each { |blob, dest, units| emit_tint_table(blob, dest, units) }
            @emitter.place_label(done)
          end

          # Put the tint the game is asking for beside the one already in the table, and
          # jump to +done+ when they are the same.
          #
          # A tint the author wrote down settles to one number while building, so the
          # compare is against a plain number. One the game works out is turned into
          # sixteenths as it runs, and r0 carries those steps on to #emit_tint_shares
          # rather than being worked out twice.
          def emit_tint_state(node, done)
            color = Color.resolve(node.color)
            if (amount = @primitives.const_int(node.amount))
              wanted = tint_state_word(color, @drawing.fade_steps(amount))
              @primitives.load_var(ACC, TINT_STATE)
              @emitter.emit(ASM.load_immediate(TMP, wanted))
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
              @emitter.emit_branch(:bcond, done, cond: :eq)
              @primitives.store_var(TMP, TINT_STATE)
              @emitter.emit(ASM.load_immediate(ACC, @drawing.fade_steps(amount)))
              return
            end

            @lowering.value(Build.binop(:/, Build.binop(:*, node.amount, Build.int(BLD_MAX)),
                                   Build.int(100)))
            @drawing.emit_clamp_blend_steps
            @emitter.emit(ASM.mov_reg(TINT_STEPS, ACC))                      # kept while the state is compared
            @emitter.emit(ASM.load_immediate(TMP, color << TINT_COLOR_SHIFT))
            @emitter.emit(ASM.orr_reg(TMP, TMP, ACC))                        # r1 = the state asked for
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:eq, TMP, 0))                     # ...but no tint is one state
            @primitives.load_var(ACC, TINT_STATE)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @primitives.store_var(TMP, TINT_STATE)
            @emitter.emit(ASM.mov_reg(ACC, TINT_STEPS))
          end

          def tint_state_word(color, steps)
            steps.zero? ? 0 : (color << TINT_COLOR_SHIFT) | steps
          end

          # Everything the walk needs that is the same for every entry: the masks, how
          # much of an original survives, and the tint color's own share of the answer.
          #
          # The color's share is worked out ONCE here rather than per entry, which is what
          # makes the inner loop as short as it is — the color does not change while a
          # table is being walked, so neither does what it contributes.
          #
          # It is kept UNSHIFTED, still multiplied up, because that is what makes the
          # rounding right: the display adds the two shares and drops the sixteenth once,
          # from the sum. Dropping it from each share first can land a whole step lower.
          #
          # r0 holds the steps on the way in.
          def emit_tint_shares(node)
            color = Color.resolve(node.color)
            @emitter.emit(ASM.load_immediate(TINT_RB, RB_MASK))
            @emitter.emit(ASM.load_immediate(TINT_G, G_MASK))
            @emitter.emit(ASM.load_immediate(TINT_KEEP, BLD_MAX))
            @emitter.emit(ASM.sub_reg(TINT_KEEP, TINT_KEEP, ACC)) # 16 sixteenths, less the tint's

            if (amount = @primitives.const_int(node.amount))
              steps = @drawing.fade_steps(amount)
              @emitter.emit(ASM.load_immediate(TINT_ADD, (color & RB_MASK) * steps))
              return @emitter.emit(ASM.load_immediate(TINT_ADD_G, (color & G_MASK) * steps))
            end

            @emitter.emit(ASM.load_immediate(TMP, color & RB_MASK))
            @emitter.emit(ASM.mul(TINT_ADD, TMP, ACC))
            @emitter.emit(ASM.load_immediate(TMP, color & G_MASK))
            @emitter.emit(ASM.mul(TINT_ADD_G, TMP, ACC))
          end

          # Walk one color table: read each original from the cartridge, blend it, write
          # it where the display reads colors from.
          #
          # The blend is the same arithmetic the display's own unit does, and the same the
          # interpreter does — each channel takes its share of the original and its share
          # of the color, the two are ADDED, and only then is the sixteenth dropped.
          # Doing it channel by channel would be three times this; masking red and blue
          # together (they sit far enough apart that a multiply cannot run one into the
          # other, and neither can the sum) does two of them in one multiply.
          def emit_tint_table(blob_name, dest, units)
            @emitter.emit_load_data_address(TINT_SRC, blob_name)
            @emitter.emit(ASM.load_immediate(TINT_DST, dest))
            @primitives.emit_add_const(TINT_END, TINT_SRC, units * 2, ACC)

            top = @emitter.gensym
            @emitter.place_label(top)
            @emitter.emit(ASM.load_halfword(ACC, TINT_SRC))        # r0 = the original color
            @emitter.emit(ASM.and_reg(TMP, ACC, TINT_RB))
            @emitter.emit(ASM.mul(TMP, TINT_KEEP, TMP))            # red and blue, both at once
            @emitter.emit(ASM.add_reg(TMP, TMP, TINT_ADD))         # + the color's share, before the drop
            @emitter.emit(ASM.lsr_imm(TMP, TMP, BLEND_SHIFT))
            @emitter.emit(ASM.and_reg(TMP, TMP, TINT_RB))
            @emitter.emit(ASM.and_reg(ACC, ACC, TINT_G))
            @emitter.emit(ASM.mul(ACC, TINT_KEEP, ACC))            # ...then green
            @emitter.emit(ASM.add_reg(ACC, ACC, TINT_ADD_G))
            @emitter.emit(ASM.lsr_imm(ACC, ACC, BLEND_SHIFT))
            @emitter.emit(ASM.and_reg(ACC, ACC, TINT_G))
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            @emitter.emit(ASM.store_halfword(ACC, TINT_DST))
            @emitter.emit(ASM.add_imm(TINT_SRC, TINT_SRC, 2))
            @emitter.emit(ASM.add_imm(TINT_DST, TINT_DST, 2))
            @emitter.emit(ASM.cmp_reg(TINT_SRC, TINT_END))
            @emitter.emit_branch(:bcond, top, cond: :ne)
          end

          # The color tables a screen draws through, as (blob, where the display reads it,
          # how many entries). The tear-free screen has one; a tiled screen has one for
          # the scenery and one for the sprites. Asked per screen because a program whose
          # scenes cross the two puts a different table in the same place on each switch,
          # so tinting must move the one the screen in force is actually reading.
          def tint_tables(mode)
            return [[PALETTE_BLOB, BG_PALETTE, @layout.palette.size]] if mode == IR::Modes::BUFFERED && @layout.palette

            tables = []
            tables << [BG_SHARED_PAL, BG_PALETTE, @layout.bg_shared[:pal_units]] if @layout.bg_shared
            tables << [@layout.obj_palette_blob, OBJ_PALETTE, @layout.obj_palette_units] if @layout.obj_palette_blob
            tables
          end

          # Every table this build has, whichever screen reads it.
          def all_tint_tables
            (tint_tables(IR::Modes::BUFFERED) + tint_tables(IR::Modes::TILED)).uniq
          end

          # How many colors each screen draws through — what a tint on that screen has to
          # move, and so what the cost model charges for one. This build knows the answer
          # exactly, because it is the thing that built the tables; nothing else does, so
          # it is handed over rather than worked out twice (see CostModel#palette_entries).
          def palette_entries
            [IR::Modes::BUFFERED, IR::Modes::TILED].to_h do |mode|
              [mode, tint_tables(mode).sum { |_blob, _dest, units| units }]
            end
          end

          # Put the color tables back exactly as they were drawn.
          #
          # This is what a FADE does on a table-drawn screen when a tint may be in force,
          # for the same reason the tint clears the fade: the display holds one
          # whole-picture effect at a time. Nothing has to be blended to undo a tint — the
          # originals are still in the cartridge — so this is the same copy the program
          # made at boot, guarded by the same compare so a game that is not tinting pays
          # only for it.
          def emit_lift_palette_tint(mode)
            skip = @emitter.gensym
            @primitives.load_var(ACC, TINT_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, TINT_STATE)
            tint_tables(mode).each { |blob, dest, units| @drawing.emit_plain_dma_blob(blob, dest, units) }
            @emitter.place_label(skip)
          end

          # A packed table cannot be read entry by entry, so a build that tints keeps its
          # color tables as plain halfwords in the cartridge. Marking them here, before
          # anything uploads them, is what stops the packer touching them (see
          # Drawing#pack_blob, which packs a blob the first time it is uploaded and
          # remembers the answer). Only a build that tints pays the few bytes.
          def keep_tint_originals_readable
            all_tint_tables.each { |blob, _dest, _units| @layout.blob_codecs[blob] = :none }
          end

          # The color tables hold what the author drew when the program starts, so the
          # remembered tint starts at nothing. Written rather than assumed: the console
          # makes no promise about what is in its memory when it powers on, and a stale
          # value here would make the first tint of the game do nothing at all.
          def emit_tint_state_init
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, TINT_STATE)
          end

          # A table has just been (re)uploaded from the cartridge, so whatever tint was in
          # it is gone. Called wherever a program puts its colors back — the boot upload,
          # and each entry into a scene whose screen re-uploads its own.
          def emit_tint_state_reset
            emit_tint_state_init if @palette_tint
          end
        end
      end
    end
  end
end
