# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # A SPRITE PLACED AS IT WAS ON THE PASS BEFORE IS LEFT AS IT IS (Lowering::Picture#
          # emit_placing_unless_unchanged). The copy of the sprite table is not wiped between
          # passes: each pass writes its sprites into it from the top (rt_sprites_begin) and
          # switches off what is left past the last (rt_sprites_end). So a sprite whose numbers —
          # whether it is on, its pose, its place, the list it is drawn with — are what they were
          # when it was last placed, and whose entries begin where they began then, already has them
          # there, and the pass moves past them. Placing a sprite is most of a pass that shows many
          # still ones, a border of a few dozen pieces.
          #
          # Whether its numbers are as they were is not asked by comparing them, which costs as much
          # as the placing nearly: the game's code that writes one of them marks the sprite changed
          # as it writes (Lowering#store, #emit_sum), and only when it writes another number than
          # the one there. What each sprite keeps: where its entries began and ended in the table
          # (START, FINISH), and in the list of what was drawn that a reader of the run takes it from
          # (DRAWN_BEFORE, DRAWN_AFTER); the round of the table they were written in (ROUND_PLACED,
          # from ROUND: a pass that hides the sprites moves every entry, and starts a new round); two
          # marks, both set while it is placed as its numbers say (PLACED): one its place, one the
          # rest, each made nought by a write of a number it is about; in a game whose sprites borrow
          # the eight lists, the list it wears, one up, and which of the eight its entries say
          # (LENT_LIST, LENT_GROUP); and whether it was last drawn from one piece in one place
          # (SAME_PIECE).
          #
          # rt_sprite_kept(HL = what the sprite keeps): Z, with the table and the list moved past the
          # sprite's entries, when it is left as it is. Otherwise NZ, with where its entries begin
          # noted, for the placing that follows — and the carry, with A its SAME_PIECE, when they
          # begin where they began and only numbers but its place changed. In a game whose sprites
          # borrow the eight lists, a sprite keeps the one it borrowed by being placed in it every
          # pass, so one left as it is still asks for its list (rt_lend_list), which marks it worn
          # this pass, and is left as it is only when the answer is the one its entries already say.
          #
          # rt_sprite_placed(HL = what the sprite keeps): the sprite has just been placed afresh:
          # where its entries ended, the round, and in a game whose sprites borrow, the list it wears
          # and which of the eight, from what rt_sprite was handed and what the lending made of it.
          module KeptSprites
            ROUND = "rt kept sprites round"
            START = 0
            FINISH = 1
            DRAWN_BEFORE = 2
            DRAWN_AFTER = 3
            ROUND_PLACED = 4
            PLACED = 5
            LENT_LIST = 6
            LENT_GROUP = 7
            # 1 when it was last placed by rt_place_kept_sprite, drawn, with every row one piece in
            # one place: rt_sprite_reposed's.
            SAME_PIECE = 8
            # Where in its block the rows of the list it was last drawn with begin, the first pose's
            # first (two bytes), for a sprite SAME_PIECE says was so drawn: a change of its pose alone
            # is the row that many rows on (rt_place_kept_sprite_pose).
            ROWS_AT = 9
            BYTES = 11

            # PLACED's marks, each made nought by a write of a number it is about (Lowering::Picture
            # #emit_sprites_changed): whether it is on and its list (and its scene's being up) are as
            # it was placed with, its place is, and its pose is.
            NUMBERS_AS_PLACED = 0
            PLACE_AS_PLACED = 1
            POSE_AS_PLACED = 3
            AS_PLACED = (1 << NUMBERS_AS_PLACED) | (1 << PLACE_AS_PLACED) | (1 << POSE_AS_PLACED)
            # Every mark up but the pose's: only its pose changed. rt_sprite_kept then adds
            # ANSWER_POSE_ALONE to the SAME_PIECE it answers with (a value in A, not a mark's bit).
            POSE_CHANGED = AS_PLACED & ~(1 << POSE_AS_PLACED)
            ANSWER_POSE_ALONE = 2
            # And one more, set by rt_place_kept_sprite with the others when the sprite was not
            # drawn — switched off, a pose none of its own, its scene not up — and left by the
            # writes. Not drawn and nothing of it changed since, nothing of it is in the table or the
            # list, and nothing is to be put there: its code passes it over without a call (Lowering::
            # Picture#emit_placing_unless_unchanged), however the sprites before it moved, which is
            # most of a game's sprites while the scene they are declared in is not up.
            NOT_DRAWN = 2
            NOT_DRAWN_AS_PLACED = AS_PLACED | (1 << NOT_DRAWN)

            # A posed sprite's block (Lowering::Picture#posed_sprite_block), read in this order by
            # rt_sprite_posed: 1 when every row is one piece in one place (one byte), that place's dx
            # and dy (one and one, nought for a sprite of more pieces), where it keeps
            # whether it is on (two, nought for always), for a sprite declared in a scene where the
            # game keeps which scene is up and the number that is this one (two and one, nought and
            # nought for a sprite of no scene), its pose (two) and how many poses (one), its
            # place (two and two), the list it is drawn with (two, nought for none) and how many lists
            # (one); then its rows, ROW_BYTES each: the picture (two), the attributes (four), in a game
            # whose sprites borrow the eight lists the list the row is drawn in (one, nought
            # otherwise), and for a row of one piece its tile and its bank and flips, as the sprite
            # table keeps them (one and one).
            ROW_BYTES = 9

            module_function

            def reserve(memory) = memory.reserve(ROUND, 1)

            def any?(memory) = memory.reserved?(ROUND)

            def emit(asm, memory, lends:)
              next_sprite = memory[Picture::NEXT_SPRITE]
              drawn = memory[Picture::DRAWN]
              asm.label("rt_sprite_kept")
              asm.push(:hl)
              asm.load(:a, [next_sprite])
              asm.cp_a([:hl]) # START
              asm.jump_relative(:nz, "rt_sprite_kept_changed")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.load(:a, [drawn])
              asm.cp_a([:hl]) # DRAWN_BEFORE
              asm.jump_relative(:nz, "rt_sprite_kept_changed")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.load(:a, [memory[ROUND]])
              asm.cp_a([:hl]) # ROUND_PLACED
              asm.jump_relative(:nz, "rt_sprite_kept_changed")
              asm.inc(:hl)
              asm.load(:a, [:hl]) # PLACED
              asm.cp_a(AS_PLACED)
              asm.jump_relative(:nz, "rt_sprite_kept_numbers")
              asm.pop(:hl)
              emit_relend(asm) if lends
              # Left as it is: the table and the list past its entries.
              asm.inc(:hl)
              asm.load(:a, [:hli]) # FINISH
              asm.load([next_sprite], :a)
              asm.inc(:hl)
              asm.load(:a, [:hl]) # DRAWN_AFTER
              asm.load([drawn], :a)
              asm.xor_a(:a) # Z
              asm.ret
              asm.label("rt_sprite_kept_changed")
              asm.pop(:hl)
              asm.label("rt_sprite_kept_afresh")
              asm.load(:a, [next_sprite])
              asm.load([:hli], :a) # START
              asm.inc(:hl)
              asm.load(:a, [drawn])
              asm.load([:hl], :a) # DRAWN_BEFORE
              asm.load(:a, 1)
              asm.and_a(:a) # NZ, and no carry
              asm.ret
              # Its entries begin where they began, in the same round, and a number of it changed:
              # when its place is as it was placed, NZ with the carry, and A its SAME_PIECE, with
              # ANSWER_POSE_ALONE added when its pose alone changed. Where its entries begin is noted
              # already, the same.
              asm.label("rt_sprite_kept_numbers")
              asm.bit(PLACE_AS_PLACED, :a) # NZ: its place is as it was placed
              asm.jump_relative(:z, "rt_sprite_kept_changed")
              asm.cp_a(POSE_CHANGED) # Z: its pose alone
              (SAME_PIECE - PLACED).times { asm.inc(:hl) }
              asm.load(:a, [:hl])
              asm.jump_relative(:nz, "rt_sprite_kept_numbers_said")
              asm.or_a(ANSWER_POSE_ALONE)
              asm.label("rt_sprite_kept_numbers_said")
              asm.pop(:hl)
              asm.scf
              asm.ret

              asm.label("rt_sprite_placed")
              asm.inc(:hl)
              asm.load(:a, [next_sprite])
              asm.load([:hli], :a) # FINISH
              asm.inc(:hl)
              asm.load(:a, [drawn])
              asm.load([:hli], :a) # DRAWN_AFTER
              asm.load(:a, [memory[ROUND]])
              asm.load([:hli], :a) # ROUND_PLACED
              asm.load(:a, AS_PLACED)
              asm.load([:hli], :a) # PLACED
              if lends
                args = SpriteArgs.new(memory, lends)
                asm.load_high(:a, args.lent)
                asm.inc(:a)
                asm.load([:hli], :a) # LENT_LIST: rt_sprite's first number, one up
                asm.load_high(:a, args.attributes)
                asm.and_a(7)
                asm.load([:hl], :a) # LENT_GROUP: its attributes' palette, which the lending put there
              end
              asm.ret

              emit_posed(asm, memory, lends: lends)
              emit_place_kept_sprite(asm, memory, lends: lends)
            end

            # rt_sprite_posed(HL = the sprite's block, A = the bank it is in, nought for the part always
            # in view; Lowering::Picture#posed_sprite_block): rt_sprite's numbers for a sprite kept as
            # it was, worked out from its block, and C = 1; or C = 0 for a sprite not drawn. What its
            # own code would work out in 32 bits — whether it is on, whether its pose is one of its
            # own, which list it is drawn with, the row of its block that pose in that list is — is a
            # byte or two each, since none of them can pass a byte and still be drawn: a number of more
            # is a sprite not drawn, or drawn in its own colours, as Lowering::Picture#sprite_placement
            # says. The block is read with its bank in view, and the caller's put back after.
            def emit_posed(asm, memory, lends:)
              emit_in_bank(asm, "rt_sprite_posed", "rt_sprite_posed_read")
              emit_in_bank(asm, "rt_sprite_pose", "rt_sprite_pose_read")
              emit_posed_read(asm, memory, lends: lends)
              emit_pose_read(asm, memory, lends: lends)
            end

            # +label+(HL = a sprite's block, A = the bank it is in, nought for the part always in
            # view): +reader+ with the block's bank in view, and the caller's put back after.
            def emit_in_bank(asm, label, reader)
              asm.label(label)
              asm.and_a(:a)
              asm.jump(:z, reader)
              asm.load(:c, :a)
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.push(:af)
              asm.load(:a, :c)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.call(reader)
              asm.pop(:af)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.ret
            end

            # Where in a block its pose's place is (Lowering::Picture#posed_sprite_block): past
            # SAME_PIECE's one byte, its piece's dx and dy (two), whether it is on (two) and its
            # scene (three).
            BLOCK_POSE = 8

            # rt_sprite_pose_read(HL = the block, its bank in view): as rt_sprite_posed_read, for a
            # sprite whose pose alone changed, its list's rows found already (SpriteArgs#rows_at): its
            # pose, one of its own, and the row that pose is — or C = 0 for a pose none of its own.
            def emit_pose_read(asm, memory, lends:)
              args = SpriteArgs.new(memory, lends)
              asm.label("rt_sprite_pose_read")
              asm.load(:de, BLOCK_POSE)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # HL at how many poses
              asm.load(:a, [:de])
              asm.load(:c, :a) # C = the pose
              emit_upper_bytes_or(asm)
              asm.jump(:nz, "rt_sprite_posed_not_drawn")
              asm.load(:a, :c)
              asm.cp_a([:hl])
              asm.jump(:nc, "rt_sprite_posed_not_drawn")
              asm.load_high(:a, args.rows_at)
              asm.load(:l, :a)
              asm.load_high(:a, args.rows_at + 1)
              asm.load(:h, :a)
              emit_pose_row(asm)
              asm.jump("rt_sprite_posed_in_place")
            end

            # rt_sprite_posed_read(HL = the block, its bank in view): as rt_sprite_posed, and the
            # piece a row of one piece is drawn from noted (Scratch#tile, #bits), with whether every
            # row is one piece in one place (Scratch#same_piece).
            def emit_posed_read(asm, memory, lends:)
              args = SpriteArgs.new(memory, lends)
              asm.label("rt_sprite_posed_not_drawn") # before the reading, where its short jumps reach
              asm.load(:c, 0)
              asm.ret
              asm.label("rt_sprite_posed_read")
              # Whether every row is one piece in one place; and so whether it is changed where it is
              # (rt_sprite_reposed), when rt_place_kept_sprite found it can be.
              asm.load(:a, [:hli])
              asm.load_high(args.same_piece, :a)
              asm.load(:b, :a)
              asm.load_high(:a, args.reposable)
              asm.and_a(:b)
              asm.load_high(args.repose, :a)
              # Where its one piece sits, when it is one (rt_sprite_one_piece).
              asm.load(:a, [:hli])
              asm.load_high(args.piece, :a)
              asm.load(:a, [:hli])
              asm.load_high(args.piece + 1, :a)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.or_a(:e)
              asm.jump_relative(:z, "rt_sprite_posed_on") # always on
              asm.load(:a, [:de])
              asm.cp_a(1)
              asm.jump_relative(:nz, "rt_sprite_posed_not_drawn")
              emit_upper_bytes_or(asm)
              asm.jump_relative(:nz, "rt_sprite_posed_not_drawn")
              asm.label("rt_sprite_posed_on")
              # Its scene up: the variable the game picks its scenes with holding the number that
              # picks this one, or nought for a sprite of no scene.
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:c, [:hl])
              asm.inc(:hl)
              asm.or_a(:e)
              asm.jump_relative(:z, "rt_sprite_posed_up")
              asm.load(:a, [:de])
              asm.cp_a(:c)
              asm.jump(:nz, "rt_sprite_posed_not_drawn")
              emit_upper_bytes_or(asm)
              asm.jump(:nz, "rt_sprite_posed_not_drawn")
              asm.label("rt_sprite_posed_up")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:de])
              asm.load(:c, :a) # C = the pose
              emit_upper_bytes_or(asm)
              asm.jump_relative(:nz, "rt_sprite_posed_not_drawn") # below nought, or past a byte: none of its poses
              asm.load(:b, [:hl]) # B = how many poses
              asm.inc(:hl)
              asm.load(:a, :c)
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_sprite_posed_not_drawn")
              # Its place: the low half of each number, which is all rt_sprite reads of it, and not
              # read at all for a sprite changed where it is.
              asm.load_high(:a, args.repose)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sprite_posed_place")
              4.times { asm.inc(:hl) }
              asm.jump_relative("rt_sprite_posed_placed")
              asm.label("rt_sprite_posed_place")
              [args.x, args.y].each do |to|
                asm.load(:a, [:hli])
                asm.load(:e, :a)
                asm.load(:a, [:hli])
                asm.load(:d, :a)
                asm.load(:a, [:de])
                asm.load_high(to, :a)
                asm.inc(:de)
                asm.load(:a, [:de])
                asm.load_high(to + 1, :a)
              end
              asm.label("rt_sprite_posed_placed")
              # Which list it is drawn with: 1 + its number for one of its lists, nought — its own
              # colours — for none, or a number naming none of them (rt_place_of_choice).
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.push(:hl) # the rows
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.load(:e, :a) # E = how many lists
              asm.load(:a, :h)
              asm.or_a(:l)
              asm.jump_relative(:z, "rt_sprite_posed_own")
              asm.load(:d, [:hl])
              asm.inc(:hl)
              asm.load(:a, [:hli])
              asm.or_a([:hl])
              asm.inc(:hl)
              asm.or_a([:hl])
              asm.jump_relative(:nz, "rt_sprite_posed_own")
              asm.load(:a, :d)
              asm.cp_a(:e)
              asm.jump_relative(:nc, "rt_sprite_posed_own")
              asm.inc(:a)
              asm.jump_relative("rt_sprite_posed_row")
              asm.label("rt_sprite_posed_own")
              asm.xor_a(:a)
              asm.label("rt_sprite_posed_row")
              # HL = the row times the poses: where that list's rows begin among the block's. The
              # product is added up a turn for each of the smaller of the two: a sprite faded through
              # dozens of lists has a few poses, and one with dozens of poses few lists.
              asm.load(:hl, 0)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sprite_posed_at")
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_sprite_posed_by_row")
              asm.load(:e, :a) # the poses at most: B turns of the row
              asm.jump_relative("rt_sprite_posed_turns")
              asm.label("rt_sprite_posed_by_row")
              asm.load(:e, :b) # fewer rows: a turn of the poses for each
              asm.load(:b, :a)
              asm.label("rt_sprite_posed_turns")
              asm.load(:d, 0)
              asm.label("rt_sprite_posed_rows")
              asm.add_hl(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_sprite_posed_rows")
              asm.label("rt_sprite_posed_at")
              emit_rows_to_bytes(asm)
              asm.pop(:hl)
              asm.add_hl(:de) # HL = the list's first row, noted for a change of the pose alone
              asm.load(:a, :l)
              asm.load_high(args.rows_at, :a)
              asm.load(:a, :h)
              asm.load_high(args.rows_at + 1, :a)
              emit_pose_row(asm)
              asm.load_high(:a, args.repose)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_sprite_posed_in_place")
              # The picture's number and the list's: the low half of the one and the low byte of the
              # other, all rt_sprite reads of them.
              asm.load(:a, [:hli])
              asm.load_high(args.picture, :a)
              asm.load(:a, [:hli])
              asm.load_high(args.picture + 1, :a)
              4.times do |i|
                asm.load(:a, [:hli])
                asm.load_high(args.attributes + i, :a)
              end
              asm.load(:a, [:hli])
              asm.load_high(args.lent, :a) if lends
              asm.label("rt_sprite_posed_piece")
              asm.load(:a, [:hli])
              asm.load_high(args.tile, :a)
              asm.load(:a, [:hl])
              asm.load_high(args.bits, :a)
              asm.load(:c, 1)
              asm.ret
              # Changed where it is (rt_sprite_reposed): its attributes, which hold its picture as the
              # list of what was drawn names it, its list and its piece, and nothing rt_sprite alone reads.
              asm.label("rt_sprite_posed_in_place")
              asm.inc(:hl)
              asm.inc(:hl)
              4.times do |i|
                asm.load(:a, [:hli])
                asm.load_high(args.attributes + i, :a)
              end
              asm.load(:a, [:hli])
              asm.load_high(args.lent, :a) if lends
              asm.jump_relative("rt_sprite_posed_piece")
            end

            # rt_place_kept_sprite(HL = what the sprite keeps, DE = its block, A = the block's bank): the
            # whole of a kept sprite's placing, so all its own code is four instructions. Left as it
            # is (rt_sprite_kept), or placed afresh (rt_sprite_posed, then rt_sprite) — or, for a
            # sprite whose numbers changed but not its place, whose every row is one piece in one place
            # and that was last placed so, with its piece's picture and list changed where it is in
            # the table (rt_sprite_reposed).
            def emit_place_kept_sprite(asm, memory, lends:)
              args = SpriteArgs.new(memory, lends)
              asm.label("rt_place_kept_sprite")
              asm.push(:hl)
              asm.push(:de)
              asm.push(:af)
              asm.call("rt_sprite_kept")
              asm.pop(:bc) # B = the bank
              asm.pop(:de)
              asm.jump(:z, "rt_place_kept_sprite_left")
              # It can be changed where it is when only its numbers but its place changed and it was
              # last placed as one piece in one place: rt_sprite_kept's carry, and A. When its pose
              # alone changed, only the pose is read (rt_place_kept_sprite_pose).
              asm.jump_relative(:nc, "rt_place_kept_sprite_unasked")
              asm.cp_a(1 | ANSWER_POSE_ALONE)
              asm.jump(:z, "rt_place_kept_sprite_pose")
              asm.and_a(1)
              asm.jump_relative("rt_place_kept_sprite_asked")
              asm.label("rt_place_kept_sprite_unasked")
              asm.xor_a(:a)
              asm.label("rt_place_kept_sprite_asked")
              asm.load_high(args.reposable, :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.load(:a, :b)
              asm.call("rt_sprite_posed")
              asm.pop(:hl)
              asm.load(:a, :c)
              asm.and_a(:a)
              asm.jump(:z, "rt_place_kept_sprite_hidden")
              asm.load_high(:a, args.repose)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_place_kept_sprite_reposed")
              asm.push(:hl)
              asm.load_high(:a, args.same_piece)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_place_kept_sprite_one_piece")
              asm.call("rt_sprite_args_set")
              asm.jump_relative("rt_place_kept_sprite_set")
              asm.label("rt_place_kept_sprite_one_piece")
              asm.call("rt_sprite_one_piece")
              asm.label("rt_place_kept_sprite_set")
              asm.pop(:hl)
              asm.push(:hl)
              asm.call("rt_sprite_placed")
              asm.pop(:hl)
              asm.load(:de, SAME_PIECE)
              asm.add_hl(:de)
              asm.load_high(:a, args.same_piece)
              asm.load([:hli], :a)
              asm.load_high(:a, args.rows_at) # ROWS_AT, which follows
              asm.load([:hli], :a)
              asm.load_high(:a, args.rows_at + 1)
              asm.load([:hl], :a)
              asm.ret
              asm.label("rt_place_kept_sprite_hidden")
              asm.push(:hl)
              asm.call("rt_sprite_placed")
              asm.pop(:hl)
              asm.load(:de, PLACED)
              asm.add_hl(:de)
              asm.set(NOT_DRAWN, [:hl])
              asm.load(:de, SAME_PIECE - PLACED)
              asm.add_hl(:de)
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.ret
              asm.label("rt_place_kept_sprite_left")
              asm.pop(:hl)
              asm.ret
              # Changed where it is, with where its list's rows begin noted, which a change of its
              # list moved.
              asm.label("rt_place_kept_sprite_reposed")
              asm.push(:hl)
              asm.load(:de, ROWS_AT)
              asm.add_hl(:de)
              asm.load_high(:a, args.rows_at)
              asm.load([:hli], :a)
              asm.load_high(:a, args.rows_at + 1)
              asm.load([:hl], :a)
              asm.pop(:hl)
              asm.jump("rt_sprite_reposed")
              emit_pose_alone(asm, args)
              emit_reposed(asm, memory, lends: lends)
            end

            # rt_place_kept_sprite_pose: a sprite whose pose alone changed since it was last drawn,
            # as one piece in one place (DE its block, B the block's bank, what it keeps on the stack).
            # Whether it is on, its scene, its list and its place are as they were, so only its pose
            # is read, and its row is the one that many on from where its list's rows begin (ROWS_AT):
            # it is changed where it is (rt_sprite_reposed). A pose none of its own is not drawn,
            # as rt_sprite_posed would find it.
            def emit_pose_alone(asm, args)
              asm.label("rt_place_kept_sprite_pose")
              asm.pop(:hl)
              asm.push(:hl)
              asm.push(:de)
              asm.load(:de, ROWS_AT)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load_high(args.rows_at, :a)
              asm.load(:a, [:hl])
              asm.load_high(args.rows_at + 1, :a)
              asm.pop(:hl) # the block
              asm.load(:a, :b)
              asm.call("rt_sprite_pose")
              asm.pop(:hl)
              asm.load(:a, :c)
              asm.and_a(:a)
              asm.jump(:z, "rt_place_kept_sprite_hidden")
              asm.jump("rt_sprite_reposed")
            end

            # rt_sprite_reposed(HL = what the sprite keeps): a sprite of one piece whose picture or list
            # changed and whose place did not, rt_sprite's numbers for it worked out already
            # (rt_sprite_posed). Its entry in the table begins where it began, and is in the table when
            # it was before, so only its tile and attributes are written in it, the list it wears
            # borrowed again as its piece goes in (rt_lend_list); and its picture in the list of what
            # was drawn. Then the table and the list are past it, as rt_sprite leaves them.
            def emit_reposed(asm, memory, lends:)
              args = SpriteArgs.new(memory, lends)
              asm.label("rt_sprite_reposed")
              asm.load(:a, [:hli]) # START
              asm.load(:e, :a)
              asm.load(:a, [:hli]) # FINISH: the table is past it already
              asm.load([memory[Picture::NEXT_SPRITE]], :a)
              asm.cp_a(:e)
              asm.jump_relative(:z, "rt_sprite_reposed_noted") # no entry: off the screen, or the table full
              asm.push(:hl)
              if lends
                asm.load_high(:a, args.lent)
                asm.inc(:a)
                asm.load(:c, :a)
                asm.push(:de)
                asm.call("rt_lend_list")
                asm.load(:a, :e)
                asm.pop(:de)
                asm.load(:b, :a)
                asm.load_high(:a, args.attributes)
                asm.or_a(:b)
                asm.load_high(args.attributes, :a)
              end
              asm.load(:l, :e)
              asm.load(:h, Memory::SHADOW_OAM >> 8)
              asm.inc(:l)
              asm.inc(:l)
              asm.load_high(:a, args.tile)
              asm.load([:hli], :a)
              asm.load_high(:a, args.bits)
              asm.load(:b, :a)
              asm.load_high(:a, args.attributes)
              asm.or_a(:b)
              asm.load([:hl], :a)
              asm.pop(:hl)
              asm.label("rt_sprite_reposed_noted") # HL at DRAWN_BEFORE
              emit_reposed_drawn(asm, memory, args)
              (DRAWN_AFTER - START).times { asm.dec(:hl) }
              asm.jump("rt_sprite_placed")
            end

            # Its picture in the list of what was drawn, when it is in it, and the list past it
            # (HL = its DRAWN_BEFORE, moved to its DRAWN_AFTER).
            def emit_reposed_drawn(asm, memory, args)
              drawn = memory[Picture::DRAWN]
              asm.load(:a, [:hli]) # DRAWN_BEFORE
              asm.load(:e, :a)
              asm.load(:a, [:hl]) # DRAWN_AFTER
              asm.load([drawn], :a)
              asm.cp_a(:e)
              asm.jump_relative(:z, "rt_sprite_reposed_counted") # not in the list: it was full
              asm.push(:hl)
              # Its row in the list, DRAWN_BYTES each past the count: its picture is the second and third.
              asm.load(:l, :e)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.load(:a, :l) # × 8, less one: × 7
              asm.sub_a(:e)
              asm.load(:l, :a)
              asm.jump_relative(:nc, "rt_sprite_reposed_row")
              asm.dec(:h)
              asm.label("rt_sprite_reposed_row")
              asm.load(:bc, drawn + 2)
              asm.add_hl(:bc)
              asm.load_high(:a, args.attributes + 2)
              asm.load([:hli], :a)
              asm.load_high(:a, args.attributes + 3)
              asm.load([:hl], :a)
              asm.pop(:hl)
              asm.label("rt_sprite_reposed_counted")
            end

            # Where rt_sprite's numbers are once rt_take_args has run, in a game whose sprites borrow
            # the eight lists (+lends+, five numbers) or not (four); and past them, what rt_sprite_posed
            # and rt_place_kept_sprite note for each other: the tile and the bank and flips of a row's one
            # piece, whether every row is one piece in one place, whether rt_place_kept_sprite found the
            # sprite can be changed where it is, and whether it is.
            SpriteArgs = Struct.new(:memory, :lends) do
              def count = lends ? 5 : 4
              def at(i) = Calls.arg(memory, i, count)
              def lent = at(0)
              def picture = at(lends ? 1 : 0)
              def x = picture - 4
              def y = picture - 8
              def attributes = picture - 12
              # The piece, as a picture's table keeps one: its dx, dy, tile and bank and flips.
              def piece = memory.args + (4 * count)
              def tile = piece + 2
              def bits = piece + 3
              def same_piece = piece + 4
              def reposable = piece + 5
              def repose = piece + 6
              def rows_at = piece + 7
            end

            # DE = HL rows of the block, ROW_BYTES each: eight times them, and once more.
            def emit_rows_to_bytes(asm)
              raise ArgumentError, "a row is counted here as nine bytes" unless ROW_BYTES == 9

              asm.load(:d, :h)
              asm.load(:e, :l)
              3.times { asm.add_hl(:hl) }
              asm.add_hl(:de)
              asm.load(:d, :h)
              asm.load(:e, :l)
            end

            # HL = the row C (the pose) rows on from HL, where a list's rows begin.
            def emit_pose_row(asm)
              asm.push(:hl)
              asm.load(:h, 0)
              asm.load(:l, :c)
              emit_rows_to_bytes(asm)
              asm.pop(:hl)
              asm.add_hl(:de)
            end

            # A = the three upper bytes of the number DE points at its lowest byte of, or'd, with DE
            # moved to its last: the zero flag says the number is a byte from 0 to 255.
            def emit_upper_bytes_or(asm)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.load(:b, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.or_a(:b)
            end

            # A sprite left as it is, in a game whose sprites borrow their lists (HL = what it keeps):
            # one that placed a piece asks for its list again, and is placed afresh unless it is
            # answered the one it is in. One that placed none borrowed none.
            def emit_relend(asm)
              asm.push(:hl)
              asm.load(:a, [:hli]) # START
              asm.cp_a([:hl]) # FINISH
              asm.jump_relative(:z, "rt_sprite_kept_lent")
              asm.load(:de, LENT_LIST - FINISH)
              asm.add_hl(:de)
              asm.load(:c, [:hl])
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.push(:af)
              asm.call("rt_lend_list")
              asm.pop(:af)
              asm.cp_a(:e)
              asm.jump_relative(:z, "rt_sprite_kept_lent")
              asm.pop(:hl)
              asm.jump_relative("rt_sprite_kept_afresh")
              asm.label("rt_sprite_kept_lent")
              asm.pop(:hl)
            end
          end
        end
      end
    end
  end
end
