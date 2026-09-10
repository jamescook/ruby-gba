# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Sixteen colours to a picture, and the picture stored half the size.
        #
        # A picture on this console is not stored as colours. Every pixel is a small
        # NUMBER that picks a colour out of a shared table, and the console will read
        # that number two ways: as a whole byte, which can name any of 256 colours, or
        # as HALF a byte, which can name 16. Half a byte is half the video memory for
        # the same picture, drawn at exactly the same speed — the console does not care
        # which it is reading, and neither does anything on screen.
        #
        # Sixteen sounds crippling and is not, because the sixteen are not the same
        # sixteen for every picture. The table is read in GROUPS of sixteen — a bank —
        # and a picture says which bank it draws from. So two pictures can have sixteen
        # colours each and share none of them, and a game keeps writing colour names
        # while its art quietly halves.
        #
        # WHAT THIS CLASS DOES is that arithmetic, once, for a set of pictures:
        #
        #   - a picture using few enough colours is NARROW: half a byte a pixel, drawn
        #     out of one bank.
        #   - a picture using more is WIDE: a whole byte a pixel, drawn out of the whole
        #     table, exactly as everything was before this existed.
        #   - narrow pictures that use the same colours share a bank, which costs
        #     nothing and is common (every frame of one walk cycle, every tile of one
        #     wall).
        #
        # Nobody writes any of this. The author writes colour names; the count decides
        # the rest.
        #
        # SLOT 0 OF A BANK IS NEVER DRAWN. The console reads the number 0 in a narrow
        # picture as "leave this pixel alone", in every bank, whatever colour sits
        # there. So a bank holds 15 colours and a see-through slot — which is also
        # exactly how art from anywhere else on this console is laid out, so an imported
        # palette drops straight in (see +authored+).
        #
        # THE WIDE PICTURES GO FIRST, and the reason is that the two kinds share one
        # table. A wide picture may use any slot; a narrow one needs a whole run of
        # sixteen. So the wide colours are packed from slot 1 up, and the banks are
        # handed out from the first whole group of sixteen above them. A game whose
        # pictures are all narrow puts nothing in the way and gets all sixteen banks.
        #
        # ---------------------------------------------------------------------------
        # IF YOU ALREADY KNOW THIS CONSOLE, here is the same thing in its own words. The
        # framework does not use them anywhere an author can see, because "four bits per
        # pixel" is a fact about the Game Boy Advance and "this picture uses sixteen
        # colours" is a fact about the picture — and only the second is something anybody
        # writing a game should have to meet. But you came here looking for them, so:
        #
        #   narrow                    4bpp — 4 bits per pixel, a nibble, two pixels to a
        #                             byte (the LEFT pixel in the LOW nibble)
        #   wide                      8bpp — 8 bits per pixel, one byte each, the 256-colour
        #                             mode everything here used before this class existed
        #   bank                      palette bank — one of the 16 groups of 16 entries the
        #                             palette is read in when a picture is 4bpp
        #   which bank a picture uses OBJ: attr2 bits 12-15 (see OBJ_BANK_SHIFT).
        #                             BG: bits 12-15 of each map entry, PER TILE (see
        #                             BG_BANK_SHIFT), so one 4bpp layer can span many banks
        #   which way it is read      OBJ: attr0 bit 13 (OBJ_256_COLOR).
        #                             BG: BGxCNT bit 7 (BG_256_COLOR). Both set = wide
        #   slot 0 is never drawn     index 0 is transparent in 4bpp, in every bank
        #
        # The bit depth is per SPRITE and per BG LAYER, never per tile — which is why a
        # layer with one greedy tile goes wide as a whole, and why all of a sprite's poses
        # share one setting. See #build_shared_object_palette and #bank_the_tiles in gba.rb
        # for the two callers.
        # ---------------------------------------------------------------------------
        class PaletteBanks
          BANKS = 16
          BANK_SIZE = 16
          CAPACITY = BANKS * BANK_SIZE

          # A bank holds this many real colours; the sixteenth slot is the see-through
          # one the console reserves.
          BANK_COLORS = BANK_SIZE - 1

          # Raised when the colours will not fit however they are arranged. The caller
          # dresses this up with the names of the pictures involved — this class knows
          # the counts, not what the author called anything.
          class Overflow < StandardError; end

          # One picture handed in: an opaque +key+ the caller will ask by, the distinct
          # colours it draws (15-bit, see-through already dropped, in first-seen order),
          # and optionally the bank the art came with.
          #
          # +authored+ is the picture's own table in its own order, see-through slot
          # first — the shape a palette exported from anywhere else on this console has.
          # It pins the bank exactly: nothing is reordered and nothing is added, because
          # the pixels of art made against that table are numbers picking out of it.
          Picture = Data.define(:key, :colors, :authored) do
            def authored? = !authored.nil?
          end

          # Where one picture ended up. +bank+ is nil for a wide picture (its numbers
          # run across the whole table); otherwise the group of sixteen it draws from.
          # +indices+ maps each of its colours to the number to write for that pixel.
          Placement = Data.define(:bank, :indices) do
            def narrow? = !bank.nil?
          end

          # +pictures+ is a list of Picture. Everything is decided here, in the
          # constructor, so the result is a value the caller can read from freely.
          def initialize(pictures)
            @pictures = pictures
            @placements = {}
            @entries = [0x0000] # slot 0: the see-through slot every picture shares
            allocate
          end

          # The colour table to upload, slot by slot.
          def entries = @entries.dup

          # Where a picture ended up, by the key it was handed in under.
          def placement(key) = @placements.fetch(key)
          def known?(key) = @placements.key?(key)

          # How many pictures got the small storage, and how many did not — the two
          # numbers a build report is made of.
          def narrow_count = @placements.count { |_key, place| place.narrow? }
          def wide_count = @placements.count { |_key, place| !place.narrow? }

          private

          # Wide first, then banks — and a picture that cannot get a bank becomes wide,
          # which changes where the banks start, so this settles rather than computes.
          # It terminates because every pass either finishes or moves at least one
          # picture from narrow to wide, and there are finitely many pictures.
          def allocate
            wide = @pictures.reject { |picture| fits_a_bank?(picture) }
            loop do
              spilled = try_allocation(wide)
              break if spilled.empty?

              wide += spilled
            end
          end

          def fits_a_bank?(picture)
            picture.authored? || picture.colors.size <= BANK_COLORS
          end

          # One attempt. Returns the pictures that found no bank, so the caller can widen
          # them and come round again; an empty list means this attempt stood.
          def try_allocation(wide)
            @placements = {}
            @entries = [0x0000]
            place_wide(wide)

            banks = [] # each: { colors: [15-bit, ...], fixed: bool }
            narrow = @pictures - wide
            spilled = []
            # Biggest first: a picture with many colours has the fewest banks it could
            # join, so letting it choose before the small ones do wastes fewer banks.
            narrow.sort_by { |picture| -picture.colors.size }.each do |picture|
              bank = bank_for(picture, banks)
              next spilled << picture if bank.nil?

              place_narrow(picture, bank, banks)
            end
            return spilled unless spilled.empty?

            write_banks(banks)
            []
          end

          # The wide pictures' colours, packed from slot 1 up in first-seen order —
          # which is what every picture on this console did before banks existed, so a
          # game with one big picture gets the same table it always got.
          def place_wide(wide)
            slots = {}
            wide.each do |picture|
              picture.colors.each do |color|
                next if slots.key?(color)

                slots[color] = @entries.size
                @entries << color
              end
            end
            raise Overflow, "#{@entries.size} colours" if @entries.size > CAPACITY

            wide.each do |picture|
              indices = picture.colors.to_h { |color| [color, slots.fetch(color)] }
              @placements[picture.key] = Placement.new(bank: nil, indices: indices)
            end
          end

          # Which bank this picture can draw from: one it already fits in, or a new one
          # if there is room for another. An authored picture will only share with a
          # bank holding exactly its table, since its numbers are pinned.
          def bank_for(picture, banks)
            found = banks.index { |bank| bank_takes?(bank, picture) }
            return found if found
            return nil if first_free_bank + banks.size >= BANKS

            banks << { colors: [], fixed: false }
            banks.size - 1
          end

          def bank_takes?(bank, picture)
            return bank[:fixed] && bank[:colors] == picture.authored if picture.authored?
            return picture.colors.all? { |color| bank[:colors].include?(color) } if bank[:fixed]

            (bank[:colors] | picture.colors).size <= BANK_COLORS
          end

          def place_narrow(picture, index, banks)
            bank = banks[index]
            if picture.authored?
              bank[:colors] = picture.authored
              bank[:fixed] = true
            elsif !bank[:fixed] # an automatic picture that joined an authored bank only reads it
              bank[:colors] |= picture.colors
            end

            slot = first_free_bank + index
            indices = picture.colors.to_h { |color| [color, slot_in(bank, color)] }
            @placements[picture.key] = Placement.new(bank: slot, indices: indices)
          end

          # An authored bank is the author's list as given, see-through slot included,
          # so a colour's number is where they put it. An automatic one reserves slot 0
          # and hands out 1 upward.
          #
          # SLOT 0 IS NEVER THE ANSWER for an authored bank, and skipping it is not a detail.
          # The first entry of a list means see-through, and the number written there is
          # 0x0000 — which is also plain black, a colour art really draws with, and the one a
          # sprite's outline is nearly always drawn in. Matching a black pixel against the
          # see-through slot hands it slot 0 and the hardware then draws nothing, so a
          # character comes out full of holes where his outline was. The author's own black
          # sits further along the list; that is the one to find.
          def slot_in(bank, color)
            return drawable_slot(bank[:colors], color) if bank[:fixed]

            bank[:colors].index(color) + 1
          end

          # Where +color+ sits in an authored list, looking only at the slots that DRAW.
          def drawable_slot(colors, color)
            (1...colors.length).find { |slot| colors[slot] == color }
          end

          # The first whole group of sixteen above the wide colours. A game with no wide
          # pictures starts at 0 and gets every bank.
          def first_free_bank
            (@entries.size + BANK_SIZE - 1) / BANK_SIZE
          end

          # Lay the banks into the table. Each starts on its own group of sixteen, so
          # anything between the wide colours and the first bank is padding nobody
          # draws.
          def write_banks(banks)
            base = first_free_bank
            banks.each_with_index do |bank, index|
              start = (base + index) * BANK_SIZE
              @entries[start, BANK_SIZE] = Array.new(BANK_SIZE, 0x0000)
              bank[:colors].each_with_index do |color, offset|
                # An automatic bank keeps slot 0 for see-through; an authored one put
                # its own see-through entry there.
                @entries[start + offset + (bank[:fixed] ? 0 : 1)] = color
              end
            end
            @entries.map! { |entry| entry || 0x0000 }
          end
        end
      end
    end
  end
end
