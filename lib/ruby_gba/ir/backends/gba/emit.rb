# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Low-level emitting and the two-pass label/branch fixup machinery — the one
        # collaborator nearly every other lowering concern depends on, since writing
        # machine code is the point of a code generator. GBA#lower builds exactly one
        # and hands it to everything else as `emitter:`.
        #
        # Two of the fixup kinds a placeholder can carry — :fast_addr, :hot_size —
        # belong to {Placement}, not here: Emit has no idea what "the quick memory" or
        # "a DMA transfer's size" mean, only how to remember a placeholder and patch it
        # once its answer is known. #resolve_fixups takes a resolver for each one this
        # class doesn't own, so a caller can add its own fixup kinds without this class
        # knowing their names — the two kinds it does own (:data_addr, :label_addr) and
        # a plain branch are resolved directly.
        class Emit
          include Console::Hardware

          # A PLACEHOLDER WAITING FOR AN ANSWER — the note the first pass leaves itself about a
          # number it cannot know yet, because the thing it refers to has not been placed.
          #
          # There are THREE of them, and they are three different things rather than one thing
          # with optional parts. That is worth saying because they used to share a single bag
          # of seven keys, where a branch's +cond+ was missing from an address load and an
          # address load's +reg+ was missing from a branch — both by design, which is exactly
          # the state in which a key that is missing on purpose cannot be told from one that is
          # missing by mistake. Each is its own record now, so asking a branch for a register
          # raises rather than answering nil and patching the wrong instruction.
          #
          # +kind+ stays on all three, because it is not the same question as which record this
          # is: it says which FLAVOUR, and #resolve_fixups dispatches on it — including to
          # resolvers for kinds this class does not own (see the note above the class).
          #
          # Nothing defaults. Where a field does not apply — a plain branch has no condition,
          # a patched-in size refers to nothing — the site writes +nil+ and says so.

          # A jump, to be written once the label's position is known. +kind+ is :b, :bcond or
          # :bl; +cond+ is the condition a :bcond branches on, and nil for the other two.
          Branch = Data.define(:pos, :kind, :target, :cond)

          # A load-immediate to be rewritten with an address once the thing is placed. +kind+
          # says whose address (:data_addr, :label_addr, :fast_addr) — or :hot_size, which is
          # the odd one: it patches the same shape of instruction with a transfer's SIZE, so it
          # refers to nothing and its +target+ is nil.
          AddressLoad = Data.define(:pos, :kind, :reg, :target)

          # A word sitting INSIDE a blob rather than in the code, holding another blob's or
          # label's run-time address — a table saying where several things are, for code that
          # picks one by number. It has no +pos+ in the code at all.
          BlobWord = Data.define(:kind, :blob, :offset, :target)

          # A COPY INTO VIDEO MEMORY THE GAME MAKES WHILE IT RUNS: where the run of instructions
          # that starts it begins in the code, what the profile calls it, and how many bytes it
          # moves. That run is gone through once per copy, so the profile's count of its first
          # instruction is the number of copies (see Profiler.video_copies_in).
          VideoCopy = Data.define(:at, :source, :bytes)

          # A word of a routine's number table that holds an address — of a blob (:data_word)
          # or of a place in the code (:label_word) — to be written once that thing is placed.
          # It is to a table what an AddressLoad is to code: the same answer, wanted as one
          # word of data instead of as four instructions that build it.
          TableWord = Data.define(:pos, :kind, :target)

          # The kind of table word that stands in for each kind of address load.
          TABLE_WORD_FOR = { label_addr: :label_word, data_addr: :data_word }.freeze

          # A LOAD A NUMBER TABLE COULD TAKE: where it sits, how many instructions it is when
          # built, and the word a table would hold for it — two loads of the same word share
          # one. Noted in every pass, whether a table is open or not, because the pass that
          # measures the routines runs with none open and still has to say what each routine
          # would save (see Placement#table_effects).
          NumberLoad = Data.define(:pos, :instructions, :word)

          # A number built from fewer instructions than this is left built: as a read and a
          # word it would be no smaller, and it would be slower.
          TABLED_FROM = 3

          attr_reader :code, :labels, :fixups, :data_blobs, :data_positions, :address_register,
                      :list_register, :video_copies, :late_pages_shown, :number_loads

          # How many jumps have been emitted so far. Counted here because this is where a
          # jump is made, and read by {Attribution}, which needs to know whether the code a
          # node came to runs the way it is written — see that class. A fixup is not the same
          # question: two of the kinds resolve to an address load rather than to a branch.
          attr_reader :branches

          def initialize
            @code = +"".b          # emitted machine code; byte 0 is where execution starts
            @labels = {}           # label name -> byte offset within @code
            @fixups = []           # branch placeholders to resolve once labels are known
            @branches = 0
            @label_seq = 0
            @data_blobs = {}       # name -> bytes (embedded data, appended after code)
            @data_positions = {}   # name -> byte offset of its blob within @code
            @data_links = []       # words inside a blob that hold another blob's address
            @video_copies = []     # run-time copies into video memory, for the profile (see VideoCopy)
            @late_pages_shown = [] # where a late page is shown at once, for the profile (see #note_late_page_shown)
            @number_loads = []     # every load a number table could take (see NumberLoad)
            @number_table = nil    # the table of the routine being emitted, when it has one
            @copied_blocks = []    # blocks copied elsewhere to run, which no plain jump may leave (see #keep_jumps_inside)
            # Everything that ends up in @code comes through here, and labels are placed
            # here too, so this is the one place that can watch a register's value survive
            # — or stop surviving — from one instruction to the next.
            @address_register = AddressRegister.new(reg: ADDR)
            @list_register = AddressRegister.new(reg: LIST_ADDR)
          end

          def emit(bytes)
            @address_register.forget_if_overwritten(bytes)
            @list_register.forget_if_overwritten(bytes)
            @code << bytes
          end

          # The current byte position — the program counter of the emit pass.
          def pos
            @code.bytesize
          end

          # A label is somewhere other code jumps to, so nothing about the registers on
          # the way here holds on the way in.
          def place_label(name)
            @address_register.forget
            @list_register.forget
            @labels[name] = pos
          end

          def gensym
            "L#{@label_seq += 1}"
          end

          # The instructions that follow start a copy of +bytes+ into video memory that the
          # profile calls +source+. Called at the head of the straight run that ends in the
          # write starting the copy — nothing may jump into that run or out of it, or the count
          # is no longer the number of copies. Nothing is emitted for it, so the cartridge is
          # the same whether anybody profiles it or not.
          def note_video_copy(source, bytes)
            @video_copies << VideoCopy.new(at: pos, source: source, bytes: bytes)
          end

          # The instructions that follow run once for each page shown at once although it was
          # finished late (see Drawing#emit_skip_wait_for_late_page), so the profile's count of
          # the first is how many there were; +tears+ says whether these show it part way down
          # the picture, where it can tear. Nothing is emitted for it.
          LatePageShown = Data.define(:at, :tears)

          def note_late_page_shown(tears:)
            @late_pages_shown << LatePageShown.new(at: pos, tears: tears)
          end

          # Emit a 4-byte branch placeholder now and remember to resolve it against
          # +target+ later. kind is :b (unconditional), :bcond (conditional), or
          # :bl (call). The real branch is written in resolve_fixups.
          def emit_branch(kind, target, cond: nil)
            # A call reaches a routine that uses the registers for its own work. What is
            # emitted here is a placeholder that only becomes a call in the second pass,
            # so nothing reading the bytes back could tell — this has to say so.
            if kind == :bl
              @address_register.forget
              @list_register.forget
            end
            @fixups << Branch.new(pos: pos, kind: kind, cond: cond, target: target)
            @branches += 1
            emit(ASM.nop)
          end

          # Call the routine whose address is already in +reg+, and come back here after.
          # This chip cannot branch-and-link to an address held in a register, so the return
          # address is set by hand — pc reads as two instructions ahead, which is the
          # instruction after the jump — and the jump itself is a BX. The routine returns
          # with BX LR.
          #
          # Every caller that reaches a routine too far away for a relative branch does this,
          # and they do it here so there is one place that knows what such a call looks like
          # — which is also the one place that can count it as a jump.
          def emit_call_through(reg)
            emit(ASM.mov_reg(14, 15)) # lr = the instruction after the jump below
            @branches += 1
            emit(ASM.bx(reg))
          end

          # --- a routine's number table (see {NumberTable}) ---

          # Give the routine that starts HERE a table for its big numbers. +measured_bytes+ is
          # the size it was measured at with every number built, and +read_within+ how far
          # from that measured end a load can be and still be read rather than built (see
          # {NumberTable}). +routine+ is its name.
          def open_number_table(measured_bytes:, read_within:, routine:)
            raise LoweringError, "a number table is already open: a routine has one, at its own end" if @number_table

            @number_table = NumberTable.new(measured_end: pos + measured_bytes, read_within: read_within, routine: routine)
          end

          # The routine is finished and has returned: write its table here, and tell each read
          # how far ahead its word turned out to be. A no-op for a routine that had no table.
          def close_number_table
            table = @number_table or return
            @number_table = nil
            table.reads.each do |read|
              ahead = table.distance_ahead(read, pos)
              refuse_unreachable_table_word!(table, ahead)
              @code[read.pos, 4] = ASM.ldr_offset(read.reg, 15, ahead)
            end
            table.words.each { |word| emit_table_word(word) }
          end

          # A BLOCK OF CODE THAT IS COPIED SOMEWHERE ON ITS OWN — by its two labels, not as part
          # of the routine around it — has to hold everything it reads. A read from a table
          # outside the block would, in the copy, name whatever happens to sit that far past
          # it. Such a block is written out by hand and builds every number, and it is emitted
          # where no table is open; this is what says so if that ever stops being true.
          def refuse_open_number_table!(what)
            return unless @number_table

            raise LoweringError,
                  "#{what} is copied on its own, so it cannot be emitted inside a routine that keeps " \
                  "a number table. This is a fault in ruby-gba, not in the game. To build the game now, " \
                  "build with `fast_code: false`."
          end

          # Put +value+ in +reg+: read from the routine's table where it has one and the
          # number is worth it, and built an instruction at a time otherwise.
          #
          # THIS IS HOW A NUMBER IS LOADED in anything emitted as part of a routine. What still
          # writes `emit(ASM.load_immediate(...))` is code written out by hand: the mixer and
          # the divide routines, which are copied on their own and must build every number
          # (see #refuse_open_number_table!), and the sound voices, the save chips and the
          # boot code, where no routine measured had a number worth a table. A new load of
          # theirs that runs inside a game's routine can use this as well.
          def emit_number(reg, value)
            built = ASM.load_immediate(reg, value)
            instructions = built.bytesize / 4
            return emit(built) if instructions < TABLED_FROM

            word = value & 0xFFFFFFFF
            note_number_load(instructions, word)
            table_takes_load? ? emit_table_read(reg, word, built_bytes: built.bytesize) : emit(built)
          end

          # Second pass: every label and data-blob position is known now, so patch
          # each placeholder — a branch to a label, or a load of a blob's / label's
          # address, or (via +extra_resolvers+) a fixup kind only the caller
          # understands, keyed by that kind and called as resolver.call(fix).
          def resolve_fixups(extra_resolvers = {})
            @fixups.each do |fix|
              case fix.kind
              when :data_addr then resolve_data_address(fix)
              when :label_addr then resolve_label_address(fix)
              when :data_word then @code[fix.pos, 4] = [data_address(fix.target)].pack("V")
              when :label_word then @code[fix.pos, 4] = [label_address(fix.target)].pack("V")
              else
                resolver = extra_resolvers[fix.kind]
                resolver ? resolver.call(fix) : resolve_branch(fix)
              end
            end
            @data_links.each do |link|
              @code[@data_positions.fetch(link.blob) + link.offset, 4] = [data_address(link.target)].pack("V")
            end
          end

          # A word +offset+ bytes into blob +blob+ that holds blob +target+'s run-time address —
          # a table saying where several things are, for code that picks one of them by number.
          # Neither blob has a place until the data region is laid out, so the word is filled in
          # with the other placeholders, in the second pass.
          def link_data(blob, offset, target)
            # The same three fields a BlobWord carries, and the same job — this one's answer is
            # always a data blob's address, so it needs no kind and no resolver.
            @data_links << BlobWord.new(kind: :data_link, blob: blob, offset: offset, target: target)
          end

          # THE CODE BETWEEN +first+ AND +last+ IS COPIED SOMEWHERE ELSE BEFORE IT RUNS — the block
          # boot copies into the quick memory. A plain jump says how far to go, not where, and the
          # distance is counted here in the cartridge, so one from inside the block to outside it,
          # or the other way, lands that far from the copy: in whatever the quick memory holds
          # there. Such a call has to load the address and jump through it (see
          # Placement#emit_call_func), and a plain one is refused as the jumps are written.
          def keep_jumps_inside(first, last) = @copied_blocks << [first, last]

          # Rewrite a branch placeholder as a real branch. The word offset is
          # (target - here)/4; ASM folds in the pipeline adjustment.
          def resolve_branch(fix)
            target = @labels.fetch(fix.target) do
              raise LoweringError, "unresolved jump to #{fix.target.inspect}"
            end
            refuse_jump_out_of_copied_block!(fix, target)
            word_offset = (target - fix.pos) / 4
            encoded =
              case fix.kind
              when :b then ASM.branch(word_offset)
              when :bcond then ASM.branch_cond(fix.cond, word_offset)
              when :bl then ASM.branch_link(word_offset)
              end
            @code[fix.pos, 4] = encoded
          end

          def refuse_jump_out_of_copied_block!(fix, target)
            @copied_blocks.each do |first, last|
              block = @labels.fetch(first)...@labels.fetch(last)
              next if block.cover?(fix.pos) == block.cover?(target)

              raise LoweringError, "a plain jump to #{fix.target.inspect} crosses the edge of the block " \
                                   "copied to the quick memory, so it would land in the wrong place"
            end
          end

          # Patch a data-address load with the blob's run-time address. The blob
          # sits at +position+ within @code, and ROM.assemble drops @code into the
          # cartridge right after the header, so its address is the cartridge base
          # plus the header plus that position.
          def resolve_data_address(fix)
            @code[fix.pos, 16] = ASM.load_immediate_fixed(fix.reg, data_address(fix.target))
          end

          # Where blob +name+ is when the cartridge runs.
          def data_address(name)
            position = @data_positions.fetch(name) do
              raise LoweringError, "reference to undefined data #{name.inspect}"
            end
            ROM_START + RubyGBA::Cartridge::ROM::ENTRY_OFFSET + position
          end

          # Patch a load with a *code label's* run-time address — the same cartridge
          # math as a data blob (base + header + position), but the position comes from
          # the label table. Used to hand the interrupt vector the address of a routine
          # that lives in the code, not in the data region.
          def resolve_label_address(fix)
            @code[fix.pos, 16] = ASM.load_immediate_fixed(fix.reg, label_address(fix.target))
          end

          # Where code label +name+ is in the cartridge when it runs.
          def label_address(name)
            position = @labels.fetch(name) do
              raise LoweringError, "reference to undefined label #{name.inspect}"
            end
            ROM_START + RubyGBA::Cartridge::ROM::ENTRY_OFFSET + position
          end

          # Load the run-time address of a named code label into +reg+ (a fixed-size
          # placeholder patched in the second pass, once the label's position is known) —
          # or, in a routine with a number table, one read of a word that is.
          def emit_load_label_address(reg, label)
            emit_load_address(reg, :label_addr, label)
          end

          # Blobs are copied into palette / video / sound memory by DMA, whose source
          # address must be aligned to its transfer unit — a halfword (2 bytes) for a
          # palette or tilemap, a word (4 bytes) for the sound FIFO. So every blob has
          # to START on an aligned address. An odd-length blob (an 8-bit sample of odd
          # length, say) would otherwise push the next blob to an odd address, and the
          # DMA would read it a byte out of step — a palette shifted by one byte tints
          # the whole screen wrong, a tilemap turns to garbage. Pad each blob up to a
          # word boundary so every one starts aligned regardless of what preceded it.
          DATA_ALIGN = 4

          # Lay the embedded blobs out after all the code, remembering where each
          # landed so resolve_data_address can turn a name into an address. Data
          # after the code means the main flow never runs into it.
          def emit_data_region
            @data_blobs.each do |name, bytes|
              emit("\x00".b * ((-pos) % DATA_ALIGN)) # pad up to the next word boundary
              @data_positions[name] = pos
              emit(bytes)
            end
          end

          # Load the run-time address of a named blob into +reg+. The address isn't
          # known until the data region is placed, so emit a fixed-size placeholder
          # and record a fixup to patch in the real address. Consumers (a blit's DMA
          # source, a sequencer's cursor) build on this. In a routine with a number table it
          # is one read of a word, and the word is what is patched.
          def emit_load_data_address(reg, name)
            emit_load_address(reg, :data_addr, name)
          end

          # A memory-mapped register / VRAM halfword write — the one ASM primitive
          # nearly every lowering concern reaches for, so it lives beside emit rather
          # than with the rest of Primitives.
          def write_reg16(address, value)
            emit_number(ACC, value)
            emit_number(TMP, address)
            emit(ASM.store_halfword(ACC, TMP))
          end

          # Patch a fixed 16-byte placeholder in place — the shape every custom fixup
          # resolver (Placement's :fast_addr/:hot_size included) writes back with.
          def patch16(pos, bytes)
            @code[pos, 16] = bytes
          end

          # Write one word of an embedded blob, +offset+ bytes into it — for a blob that is a
          # table of addresses only known in the second pass.
          def patch_word(blob, offset, value)
            @code[@data_positions.fetch(blob) + offset, 4] = [value].pack("V")
          end

          private

          # Load an address the second pass fills in — of code label or blob +target+, as
          # +kind+ says — as one read of a table word where the routine has a table that
          # reaches, and as the fixed four instructions otherwise.
          def emit_load_address(reg, kind, target)
            word = NumberTable::Address.new(kind: TABLE_WORD_FOR.fetch(kind), target: target)
            note_number_load(4, word)
            return emit_table_read(reg, word, built_bytes: 16) if table_takes_load?

            @fixups << AddressLoad.new(pos: pos, kind: kind, reg: reg, target: target)
            emit(ASM.load_immediate_fixed(reg, 0))
          end

          def note_number_load(instructions, word)
            @number_loads << NumberLoad.new(pos: pos, instructions: instructions, word: word)
          end

          # Is a table open, and is a load HERE one it reads rather than one that is built?
          def table_takes_load? = !@number_table.nil? && @number_table.reaches?(pos)

          # One read of +word+ into +reg+, in place of a load +built_bytes+ long. How far
          # ahead the word is gets written when the table is; until then the read names the
          # word right after it.
          def emit_table_read(reg, word, built_bytes:)
            @number_table.note_read(pos, reg, word, built_bytes: built_bytes)
            emit(ASM.ldr_offset(reg, 15, 0))
          end

          # One word of a table: the number itself, or room for an address that the second
          # pass fills in.
          def emit_table_word(word)
            return emit([word].pack("V")) unless word.is_a?(NumberTable::Address)

            @fixups << TableWord.new(pos: pos, kind: word.kind, target: word.target)
            emit([0].pack("V"))
          end

          # The table is at the routine's end and a read is too far above it. That is a
          # routine that came out bigger than the most it was said it could be, so every
          # "does this reach" asked while it was emitted was asked against the wrong end.
          def refuse_unreachable_table_word!(table, ahead)
            return if NumberTable.within_reach?(ahead)

            raise LoweringError,
                  "The routine #{table.routine.inspect} reads a number that is #{ahead} bytes ahead of the " \
                  "instruction that reads it. The furthest a read can reach is #{NumberTable::FURTHEST} bytes. " \
                  "The routine came out bigger than the size it was measured at. This is a fault in " \
                  "ruby-gba, not in the game. To build the game now, build with `fast_code: false`."
          end
        end
      end
    end
  end
end
