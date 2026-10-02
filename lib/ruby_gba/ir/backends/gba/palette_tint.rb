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
          include Console::Hardware

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

          # A walk counts in thirty-seconds, as fine as a channel goes, so dividing by 32 is a
          # shift of 5 (see IR::Fading). The display's blend counts in sixteenths, and a
          # sixteenth is two thirty-seconds, so a tint asked for in sixteenths walks to the
          # same colors it always did.
          #
          # Why no finer: red and blue are blended in one multiply, and red times 32 still
          # fits in the ten bits below blue. Times 64 would run into it.
          WALK_STEPS = FadeSteps::WALK
          BLEND_SHIFT = 5

          # Registers held across the walk. It runs as a whole statement, so every
          # register but the variable-address scratch is free.
          TINT_SRC = 2   # where the originals are being read from (the cartridge)
          TINT_DST = 3   # where the blended entries are being written (the color table)
          TINT_END = 4   # one past the last original, which is what ends the walk
          TINT_KEEP = 5  # how much of the original survives, in thirty-seconds
          TINT_RB = 6    # the red/blue mask, held rather than rebuilt per entry
          TINT_G = 7     # the green mask, likewise
          TINT_ADD = 8   # the color's own red and blue share — the same for every entry
          TINT_ADD_G = 9 # ...and its green one
          TINT_STEPS = 10 # where the steps wait while the remembered tint is compared

          TINT_COLOR_SHIFT = 6 # the steps (0..32) sit below the color in the state word

          # A FADE TOWARD BLACK, which is not quite a tint toward black. A mix KEEPS a share of
          # each channel and drops the fraction, so it rounds down; the display's own fade takes
          # a share AWAY and drops the fraction of that, so it rounds up. On a dark picture the
          # two are a whole frame apart at the end of a fade in — the mix is still flat black
          # on a frame where the display's fade already shows the picture. So a walked fade
          # rounds the way the display does: nearly one whole step (31 thirty-seconds) is added
          # to each channel before the fraction is dropped. Toward white the two rules are
          # already the same one.
          #
          # It is said as a color no picture can have — the bit above a 15-bit color — so it
          # rides in the state word like any color, tells a fade to black from `tint :black`,
          # and contributes nothing to the shares but the rounding.
          DARKEN = 0x8000

          # The palette layout this object reads, handed over once the prepare passes that
          # decide it have all run (see #layout=): the color table a buffered scene draws
          # through, the screen's layout ({ScreenLayout}, which made the shared background
          # table and the sprite table), and the codec map a tint marks so its tables stay
          # readable in the cartridge.
          Layout = Data.define(:palette, :screen, :blob_codecs) do
            def bg_shared = screen.bg_shared
            def obj_palette_blob = screen.obj_palette_blob
            def obj_palette_units = screen.obj_palette_units
            def scene_obj_palettes = screen.scene_obj_palettes
            def bg_recolor_restore_banks = screen.bg_recolor_restore_banks
          end

          # WHERE THE SPRITE COLOURS ON SCREEN NOW CAME FROM, in a game whose scenes each send
          # a table of their own (see ScreenLayout#build_shared_object_palette). A walk has to
          # start from the originals of the table the console is really holding, and which one
          # that is changes as the game runs, so it is kept in a variable rather than named.
          OBJ_TABLE_AT = :_obj_table_at

          # Does the sprite table this build walks change as scenes take over?
          def scene_obj_tables? = @layout.scene_obj_palettes.any?

          # Say which sprite table is in the console now, at power-on or on a change of screen,
          # where the one every screen shows has just been sent. Nothing for a build that never
          # walks a table, or has only the one.
          def emit_record_obj_palette_source(blob)
            return unless @palette_tint && scene_obj_tables?

            @emitter.emit_load_data_address(ACC, blob)
            @primitives.store_var(ACC, OBJ_TABLE_AT)
          end

          # SEND A SCENE'S SPRITE COLOURS AS IT TAKES OVER. A plain copy, unless this build moves
          # its colour tables — then the table goes in through whatever tint or fade is in force,
          # the same way a layer's other colours do (see #emit_colors_into_bank), because a
          # plain copy into a screen that is meant to be dark would bring this scene's sprites
          # in at full brightness. It also says this table is the one to walk from now on.
          def emit_send_scene_obj_palette(blob, units)
            return @drawing.emit_plain_dma_blob(blob, OBJ_PALETTE, units) unless @palette_tint

            @emitter.emit_load_data_address(ACC, blob)
            @primitives.store_var(ACC, OBJ_TABLE_AT)
            emit_colors_into_bank(OBJ_PALETTE, units)
          end

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

          # Does this program move a color table at all, and does it fade at all? Both
          # answers decide code that is emitted far from the tint itself — whether the
          # tables have to stay readable in the cartridge, whether boot clears the state
          # variable, whether a fade has to lift a tint that may be in force — so they are
          # worked out once, before anything is emitted.
          #
          # A table is moved by a `tint` on a screen that draws through one, and by a fade
          # that walks the colors rather than taking the display's blend (see IR::Fading).
          # Both land in the same tables and both are remembered in the same state word,
          # which is the display's own "one whole-picture effect at a time" rule.
          #
          # A build that never moves a table must come out byte for byte as it did before
          # any of this existed, which is what every flag here is for.
          def prepare_palette_tint(program, fading:)
            @program_fades = program.walk.any? { |node| node.kind == :fade }
            @palette_tint = program.walk.any? { |node| node.kind == :tint && palette_screen?(node) } ||
                            fading.any_fade_walks_palette?
            @darkens = program.walk.any? do |node|
              node.kind == :fade && node.toward == :black && fading.palette_walk?(node)
            end
            mark_tint_tables_unpacked if @palette_tint
          end

          # Does this build move a color table at all? Named for what it asks rather than
          # for this class, because a fade asks it too now and "does it tint" would be the
          # wrong question — what the callers want to know is whether the tables are
          # rewritten while the game runs, whoever is rewriting them.
          def moves_color_table?
            @palette_tint
          end

          # Is the statement on a screen that draws through a color table? The tear-free
          # bitmap screen and the tiled screen both do; the direct-color screen does not,
          # and tints through the display's blend unit instead (ScreenEffects#emit_tint).
          def palette_screen?(node)
            @modes.mode_at(node) != IR::Modes::DIRECT
          end

          # Mix a color into a picture drawn through a color table.
          #
          # Asked for by what it needs rather than by which statement asked, because two
          # statements do: a `tint` names its own color, and a fade that walks the colors
          # is this same walk toward black or white (see ScreenEffects#emit_fade). +color+ is
          # already resolved, +amount+ is the 0-to-100 the author wrote or the game works
          # out, and +mode+ is the screen whose tables are to be moved.
          #
          # The guard comes first and is the whole reason this is affordable. A game
          # writes `tint :red, hurt` on every pass of its loop, and `hurt` is 0 for almost
          # all of them — so the common frame compares one variable, finds nothing has
          # moved, and jumps over the walk entirely.
          def emit_palette_tint(color:, amount:, mode:, fraction_bits: nil)
            # The tint and the fade are one effect: the display can only be told one
            # thing about the whole picture at a time, and the interpreter models the same
            # rule. So asking for a tint puts away whatever fade was in force.
            @emitter.write_reg16(REG_BLDY, 0) if @program_fades

            done = @emitter.gensym
            written = @primitives.const_int(amount)
            steps = written && FadeSteps.steps(written, fraction_bits: fraction_bits, walked: true)
            asked = steps || FadeSteps.steps_value(amount, fraction_bits: fraction_bits, walked: true)
            emit_tint_state(color, asked, done) # r0 = the steps, when the game works them out
            emit_tint_shares(color, steps)
            tint_tables(mode).each { |blob, dest, units| emit_tint_table(blob, dest, units) }
            emit_recolored_banks # ...and put back what those walks wrote over
            @emitter.place_label(done)
          end

          # Put the tint the game is asking for beside the one already in the table, and
          # jump to +done+ when they are the same.
          #
          # A tint the author wrote down settles to a number of steps while building, so the
          # compare is against a plain number. One the game works out arrives as the value
          # that turns it into thirty-seconds as it runs, and r0 carries those steps on to
          # #emit_tint_shares rather than their being worked out twice.
          def emit_tint_state(color, steps, done)
            if steps.is_a?(Integer)
              @primitives.load_var(ACC, TINT_STATE)
              @emitter.emit(ASM.load_immediate(TMP, tint_state_word(color, steps)))
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
              @emitter.emit_branch(:bcond, done, cond: :eq)
              @primitives.store_var(TMP, TINT_STATE)
              @emitter.emit(ASM.load_immediate(ACC, steps))
              return
            end

            @lowering.value(steps)
            @drawing.emit_clamp_blend_steps(WALK_STEPS)
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
          # rounding right: the display adds the two shares and drops the fraction once,
          # from the sum. Dropping it from each share first can land a whole step lower.
          #
          # r0 holds the steps on the way in; +steps+ is them again when they were written
          # down, and nil when the game works them out.
          def emit_tint_shares(color, steps)
            @emitter.emit(ASM.load_immediate(TINT_RB, RB_MASK))
            @emitter.emit(ASM.load_immediate(TINT_G, G_MASK))
            @emitter.emit(ASM.load_immediate(TINT_KEEP, WALK_STEPS))
            @emitter.emit(ASM.sub_reg(TINT_KEEP, TINT_KEEP, ACC)) # 32 thirty-seconds, less the tint's

            darken = color == DARKEN
            if steps
              @emitter.emit(ASM.load_immediate(TINT_ADD, ((color & RB_MASK) * steps) + (darken ? RB_MASK : 0)))
              return @emitter.emit(ASM.load_immediate(TINT_ADD_G, ((color & G_MASK) * steps) + (darken ? G_MASK : 0)))
            end

            @emitter.emit(ASM.load_immediate(TMP, color & RB_MASK))
            @emitter.emit(ASM.mul(TINT_ADD, TMP, ACC))
            @emitter.emit(ASM.load_immediate(TMP, color & G_MASK))
            @emitter.emit(ASM.mul(TINT_ADD_G, TMP, ACC))
            return unless darken

            @emitter.emit(ASM.add_reg(TINT_ADD, TINT_ADD, TINT_RB))   # ...rounded the display's way
            @emitter.emit(ASM.add_reg(TINT_ADD_G, TINT_ADD_G, TINT_G))
          end

          # Walk one color table: read each original from the cartridge, blend it, write
          # it where the display reads colors from.
          #
          # The blend is the same arithmetic the display's own unit does, and the same the
          # interpreter does — each channel takes its share of the original and its share
          # of the color, the two are ADDED, and only then is the fraction dropped.
          # Doing it channel by channel would be three times this; masking red and blue
          # together (they sit far enough apart that a multiply cannot run one into the
          # other, and neither can the sum) does two of them in one multiply.
          def emit_tint_table(blob_name, dest, units)
            emit_table_source(TINT_SRC, blob_name)
            emit_blend_run(dest, units)
          end

          # Point +reg+ at a table's originals: the sprite table the console is holding now,
          # when scenes take turns with it, and otherwise the one table there is.
          def emit_table_source(reg, blob_name)
            if blob_name == @layout.obj_palette_blob && scene_obj_tables?
              @primitives.load_var(reg, OBJ_TABLE_AT)
            else
              @emitter.emit_load_data_address(reg, blob_name)
            end
          end

          # The walk itself, from wherever TINT_SRC has been pointed. Two things are read
          # through it: the tables a screen draws through, and the list of colours a layer
          # that can be recoloured is drawing from (see #emit_colors_into_bank).
          def emit_blend_run(dest, units)
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

          # PUT A LAYER'S OTHER COLOURS INTO THE GROUP ITS TILES READ, through whatever tint
          # is in force. ACC holds where the list starts on the way in; +dest+ is where that
          # group of sixteen sits in the table.
          #
          # WHY IT GOES THROUGH THE TINT RATHER THAN STRAIGHT IN. Two things write this one
          # table, and a game can do both: a tint moves every colour the game declared, and a
          # layer told `draw_with` replaces sixteen of them. A plain copy would put full
          # brightness back into the middle of a screen that is meant to be dark — one layer
          # glowing through a fade. With no tint in force the arithmetic is the identity
          # (keep all thirty-two thirty-seconds, add nothing), so a game that never tints pays a few
          # instructions on a frame where the colours changed and nothing else.
          def emit_colors_into_bank(dest, units)
            @emitter.emit(ASM.mov_reg(TINT_SRC, ACC))
            emit_tint_shares_from_state
            emit_blend_run(dest, units)
          end

          # ...and the other half of the same agreement: once a tint has walked the tables,
          # the entries it has just written over a recoloured layer's group are the colours
          # that layer was DRAWN in, which is not what it is being drawn with. So each such
          # group is written again, from the list it is really showing.
          #
          # The layout's +bg_recolor_restore_banks+ are (where the group sits, the variable holding
          # where its layer's current version starts, how far along that version this group's
          # list is) — nought in that variable meaning the layer has never been told anything,
          # where the tables already hold the right colours.
          def emit_recolored_banks
            @layout.bg_recolor_restore_banks.each do |dest, source_var, along|
              @primitives.load_var(TINT_SRC, source_var)
              @emitter.emit(ASM.cmp_imm(TINT_SRC, 0))
              past = @emitter.gensym
              @emitter.emit_branch(:bcond, past, cond: :eq)
              @emitter.emit(ASM.add_imm(TINT_SRC, TINT_SRC, along)) unless along.zero?
              emit_blend_run(dest, COLORS_IN_A_BANK)
              @emitter.place_label(past)
            end
          end

          # A group of colours a layer's tiles draw from holds sixteen of them.
          COLORS_IN_A_BANK = 16

          # The shares (see #emit_tint_shares) worked out from the tint the table is already
          # holding rather than from one being asked for now — for the caller that has no
          # tint statement in front of it. The state packs the colour above the steps, and
          # nought means the table holds the originals, which comes out as the identity.
          def emit_tint_shares_from_state
            @primitives.load_var(ACC, TINT_STATE)
            @emitter.emit(ASM.lsr_imm(TINT_STEPS, ACC, TINT_COLOR_SHIFT))  # the colour
            @emitter.emit(ASM.and_imm(ACC, ACC, (1 << TINT_COLOR_SHIFT) - 1)) # ...and the steps
            @emitter.emit(ASM.load_immediate(TINT_RB, RB_MASK))
            @emitter.emit(ASM.load_immediate(TINT_G, G_MASK))
            @emitter.emit(ASM.load_immediate(TINT_KEEP, WALK_STEPS))
            @emitter.emit(ASM.sub_reg(TINT_KEEP, TINT_KEEP, ACC))
            @emitter.emit(ASM.and_reg(TMP, TINT_STEPS, TINT_RB))
            @emitter.emit(ASM.mul(TINT_ADD, TMP, ACC))
            @emitter.emit(ASM.and_reg(TMP, TINT_STEPS, TINT_G))
            @emitter.emit(ASM.mul(TINT_ADD_G, TMP, ACC))
            return unless @darkens

            # A fade toward black in force rounds the display's way (see DARKEN). Only a build
            # that walks one pays the three instructions.
            @emitter.emit(ASM.tst_imm(TINT_STEPS, DARKEN))
            @emitter.emit(ASM.add_reg_cond(:ne, TINT_ADD, TINT_ADD, TINT_RB))
            @emitter.emit(ASM.add_reg_cond(:ne, TINT_ADD_G, TINT_ADD_G, TINT_G))
          end

          # The color tables a screen draws through, as (blob, where the display reads it,
          # how many entries). The tear-free screen has one; a tiled screen has one for
          # the scenery and one for the sprites. Asked per screen because a program whose
          # scenes cross the two puts a different table in the same place on each switch,
          # so tinting must move the one the screen in force is actually reading.
          def tint_tables(mode)
            return [[PALETTE_BLOB, BG_PALETTE, @layout.palette.size]] if mode == IR::Modes::BUFFERED && @layout.palette

            tables = []
            tables << [BG_SHARED_PAL, BG_PALETTE, @layout.bg_shared.palette_units] if @layout.bg_shared
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
            tint_tables(mode).each { |blob, dest, units| emit_restore_palette_table(blob, dest, units) }
            @emitter.place_label(skip)
          end

          # Copy a table's originals back into place, from wherever #emit_table_source says they are.
          def emit_restore_palette_table(blob, dest, units)
            return @drawing.emit_plain_dma_blob(blob, dest, units) unless blob == @layout.obj_palette_blob && scene_obj_tables?

            emit_table_source(ACC, blob)
            @emitter.emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            @emitter.emit(ASM.str(ACC, TMP))
            @primitives.store_word_immediate(dest, REG_DMA3DAD)
            @primitives.store_word_immediate(units | DMA_ENABLE, REG_DMA3CNT)
          end

          # A packed table cannot be read entry by entry, so a build that tints keeps its
          # color tables as plain halfwords in the cartridge. Marking them here, before
          # anything uploads them, is what stops the packer touching them (see
          # BlobUpload#pack_blob, which packs a blob the first time it is uploaded and
          # remembers the answer). Only a build that tints pays the few bytes.
          def mark_tint_tables_unpacked
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
          def emit_tint_reset_if_tinting
            emit_tint_state_init if @palette_tint
          end
        end
      end
    end
  end
end
