# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # PICTURES GROUPED BY ROOM (Builder::PictureGroups), copied into sprite memory as a room
          # comes up.
          #
          # The Color draws its sprites from 256 tiles of picture memory, which a game of many rooms
          # would fill many times over. So a grouped picture is not copied in at power-on: it has one
          # place in a room of its set's own, shared with the pictures whose groups are never up
          # with its own (IR::PictureGroupPlaces, GBC::Art#group_rooms), and its tiles are copied
          # there as one of its groups comes up, the way the console's own games load a room's
          # things as the room loads.
          #
          # The game says which groups are up (Lowering::Picture#emit_show_picture_group), and as
          # it places a pass's sprites it notes which groups those sprites need: the ones up then
          # (#emit_groups_wanted). The blank after copies in any group a slot wants that is not the
          # one it holds. Picture memory can be written only while the display is not reading it,
          # so a group is copied CHUNKS_A_BLANK chunks a blank — a chunk being at most CHUNK_TILES
          # tiles — and a bigger one takes more blanks: the frame then waits for the next blank, as
          # it does for a grid being put up, with the sprite layer off, since the sprites placed
          # would be drawn from tiles only part copied.
          #
          # The tables, written by #emit_slot and #emit_chunk (for Lowering::Picture#emit_group_slots and
          # Art#emit_group_tables), so their layout is said in this one place:
          # - game_group_slots: for each slot of each set, the place of the group it wants (a byte,
          #   NONE for none, FOLLOW for the one the game says), the place of the one it holds, the
          #   place of the number the game said (four bytes), the bank of its set's tiles, its set's
          #   table of groups and how many groups the set has; then a word of nought.
          # - a set's table of groups: for each group, how many chunks it copies and where their
          #   list is.
          # - a chunk: where its tiles are in the bank, the bank of picture memory they go to, where
          #   they go, and how many blocks of 16 bytes less one, as the console's own copy takes it.
          module PictureGroups
            # The most tiles in a chunk, and the most chunks copied in one blank: 512 bytes, as many as
            # the blank copies of a grid being put up (Picture::MAP_ROWS_PER_BLANK rows of it).
            CHUNK_TILES = 8
            CHUNKS_A_BLANK = 4

            # A slot that wants no group, and one that holds nothing yet.
            NONE = 0xFF
            NOTHING_YET = 0xFE

            # A slot of a scene that was not up as the sprites were placed. The interpreter asks
            # nothing of such a scene's sprites (Reference#up_in_this_scene?), and the scene can
            # take over later in the same pass and say which groups are up, as it does on its first
            # pass: so the blank copies in the group the game says is up by then.
            FOLLOW = 0xFD

            # The most groups a set can have, numbered from 0 below the three numbers above.
            MOST_GROUPS = FOLLOW

            # Where each thing is in a slot's entry of game_group_slots, and how big an entry of a
            # set's table of groups is.
            SLOT_UP = 2
            SLOT_SAID = 4
            SLOT_BANK = 6
            SLOT_COUNT = 9
            SLOT_BYTES = 10
            GROUP_BYTES = 3

            # The group being copied: how many chunks are left, where the next one is, and the bank
            # its tiles are in; then 0xFF while a group is still being copied in, as the blank left
            # it, for the screen's switches (Picture#emit_upload).
            JOB = "rt groups job"
            PENDING = 4
            JOB_BYTES = PENDING + 1

            module_function

            def reserve(memory)
              memory.reserve(JOB, JOB_BYTES)
            end

            # A slot's entry of game_group_slots: the places of the group it wants, the one it holds
            # and the number the game said; the label of its set's tiles, for their bank; its set's
            # table of groups; and how many groups the set has. In that order, SLOT_UP to SLOT_COUNT saying where each is.
            def emit_slot(asm, wanted:, up:, said:, tiles:, groups:, count:)
              asm.data_words(wanted, up, said)
              asm.data_bank_of(tiles)
              asm.data_words(groups)
              asm.data_bytes(count)
            end

            # An entry of a set's table of groups: how many chunks the group copies, and their list.
            def emit_group(asm, chunks:, list:)
              asm.data_bytes(chunks)
              asm.data_words(list)
            end

            # A chunk of a group's list: the label of its tiles, the bank of picture memory and the
            # place they go, and how many tiles, as rt_groups_upload reads them.
            def emit_chunk(asm, tiles:, bank:, to:, count:)
              asm.data_words(tiles)
              asm.data_bytes(bank)
              asm.data_words(to)
              asm.data_bytes(count - 1)
            end

            def emit(asm, memory)
              h = Console::GBCHardware
              job = memory[JOB]
              # rt_groups_upload, in the blank: carry set when a group is still being copied in.
              asm.label("rt_groups_upload")
              asm.load(:b, CHUNKS_A_BLANK)
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_groups_upload_next")
              asm.load(:b, 0xFF) # with the screen off, every chunk now
              asm.label("rt_groups_upload_next")
              asm.load(:a, [job])
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_groups_upload_chunk")
              asm.push(:bc)
              asm.call("rt_groups_start")
              asm.pop(:bc)
              asm.jump_relative(:nz, "rt_groups_upload_next")
              asm.call("rt_groups_upload_done")
              asm.and_a(:a) # carry clear: every slot holds what it wants
              asm.ret
              asm.label("rt_groups_upload_chunk")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_groups_upload_more")
              asm.dec(:b)
              asm.push(:bc)
              asm.load(:a, [job + 3])
              asm.load([h::MBC_ROM_BANK_LOW], :a)
              asm.load(:a, [job + 1])
              asm.load(:l, :a)
              asm.load(:a, [job + 2])
              asm.load(:h, :a)
              asm.load(:a, [:hli]) # where the tiles are...
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli]) # ...the bank of picture memory...
              asm.load_high(h::VBK, :a)
              asm.load(:a, [:hli]) # ...where they go...
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:a, [:hli]) # ...and how many blocks, less one
              asm.push(:af)
              asm.load(:a, :l)
              asm.load([job + 1], :a)
              asm.load(:a, :h)
              asm.load([job + 2], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.load(:d, :b)
              asm.load(:e, :c)
              asm.pop(:af)
              asm.load(:c, :a)
              asm.call("rt_gdma")
              asm.load(:hl, job)
              asm.dec([:hl])
              asm.pop(:bc)
              asm.jump_relative("rt_groups_upload_next")
              asm.label("rt_groups_upload_more")
              asm.call("rt_groups_upload_done")
              asm.scf
              asm.ret
              asm.label("rt_groups_upload_done")
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.jump("rt_bank_back")

              # rt_groups_start: the first slot that wants a group it does not hold now holds it, and
              # its group's chunks are the job (none, for a number naming no group). NZ when a slot
              # changed, Z when every slot holds what it wants.
              asm.label("rt_groups_start")
              asm.load(:hl, "game_group_slots")
              asm.label("rt_groups_start_slot")
              asm.load(:a, [:hli]) # the place of the group it wants
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.or_a(:e)
              asm.ret(:z) # the end of the table
              asm.load(:a, [:de])
              asm.load(:c, :a)
              asm.cp_a(FOLLOW)
              asm.call(:z, "rt_groups_follow")
              asm.load(:a, [:hli]) # the place of the one it holds
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:de])
              asm.cp_a(:c)
              asm.jump_relative(:nz, "rt_groups_start_change")
              asm.load(:de, SLOT_BYTES - SLOT_SAID) # to the next slot
              asm.add_hl(:de)
              asm.jump_relative("rt_groups_start_slot")
              asm.label("rt_groups_start_change")
              asm.load(:a, :c)
              asm.load([:de], :a)
              (SLOT_BANK - SLOT_SAID).times { asm.inc(:hl) } # past the number the game said
              asm.load(:a, [:hli]) # the bank of the set's tiles
              asm.load([job + 3], :a)
              asm.load(:a, [:hli]) # the set's table of groups
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hl]) # how many groups it has
              asm.load(:b, :a)
              asm.load(:a, :c)
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_groups_start_none")
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.load(:b, 0)
              GROUP_BYTES.times { asm.add_hl(:bc) }
              asm.load(:a, [:hli]) # how many chunks
              asm.load([job], :a)
              asm.load(:a, [:hli])
              asm.load([job + 1], :a)
              asm.load(:a, [:hl])
              asm.load([job + 2], :a)
              asm.label("rt_groups_start_none")
              asm.load(:a, 1)
              asm.and_a(:a)
              asm.ret

              # rt_groups_follow, HL at the slot's place of the group it holds: C, the group the
              # number the game said names, or NONE for one naming none — below nought, or past the
              # set's groups. HL is kept.
              asm.label("rt_groups_follow")
              asm.push(:hl)
              asm.load(:c, NONE)
              (SLOT_SAID - SLOT_UP).times { asm.inc(:hl) }
              asm.load(:a, [:hli]) # the place of the number
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              (SLOT_COUNT - SLOT_BANK).times { asm.inc(:hl) } # past the bank and the table
              asm.load(:b, [:hl])
              asm.load(:a, [:de])
              asm.load(:l, :a) # its low byte
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.load(:h, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.or_a(:h)
              asm.load(:h, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.or_a(:h)
              asm.jump_relative(:nz, "rt_groups_follow_done") # past a byte, or below nought
              asm.load(:a, :l)
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_groups_follow_done")
              asm.load(:c, :a)
              asm.label("rt_groups_follow_done")
              asm.pop(:hl)
              asm.ret
            end
          end
        end
      end
    end
  end
end
