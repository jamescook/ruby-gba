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
          include Constants

          attr_reader :code, :labels, :fixups, :data_blobs, :data_positions, :address_register

          def initialize
            @code = +"".b          # emitted machine code; byte 0 is where execution starts
            @labels = {}           # label name -> byte offset within @code
            @fixups = []           # branch placeholders to resolve once labels are known
            @label_seq = 0
            @data_blobs = {}       # name -> bytes (embedded data, appended after code)
            @data_positions = {}   # name -> byte offset of its blob within @code
            # Everything that ends up in @code comes through here, and labels are placed
            # here too, so this is the one place that can watch a register's value survive
            # — or stop surviving — from one instruction to the next.
            @address_register = AddressRegister.new(reg: ADDR)
          end

          def emit(bytes)
            @address_register.saw(bytes)
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
            @labels[name] = pos
          end

          def gensym
            "L#{@label_seq += 1}"
          end

          # Emit a 4-byte branch placeholder now and remember to resolve it against
          # +target+ later. kind is :b (unconditional), :bcond (conditional), or
          # :bl (call). The real branch is written in resolve_fixups.
          def emit_branch(kind, target, cond: nil)
            # A call reaches a routine that uses the registers for its own work. What is
            # emitted here is a placeholder that only becomes a call in the second pass,
            # so nothing reading the bytes back could tell — this has to say so.
            @address_register.forget if kind == :bl
            @fixups << { pos: pos, kind: kind, cond: cond, target: target }
            emit(ASM.nop)
          end

          # Second pass: every label and data-blob position is known now, so patch
          # each placeholder — a branch to a label, or a load of a blob's / label's
          # address, or (via +extra_resolvers+) a fixup kind only the caller
          # understands, keyed by that kind and called as resolver.call(fix).
          def resolve_fixups(extra_resolvers = {})
            @fixups.each do |fix|
              case fix[:kind]
              when :data_addr then resolve_data_address(fix)
              when :label_addr then resolve_label_address(fix)
              else
                resolver = extra_resolvers[fix[:kind]]
                resolver ? resolver.call(fix) : resolve_branch(fix)
              end
            end
          end

          # Rewrite a branch placeholder as a real branch. The word offset is
          # (target - here)/4; ASM folds in the pipeline adjustment.
          def resolve_branch(fix)
            target = @labels.fetch(fix[:target]) do
              raise LoweringError, "unresolved jump to #{fix[:target].inspect}"
            end
            word_offset = (target - fix[:pos]) / 4
            encoded =
              case fix[:kind]
              when :b then ASM.branch(word_offset)
              when :bcond then ASM.branch_cond(fix[:cond], word_offset)
              when :bl then ASM.branch_link(word_offset)
              end
            @code[fix[:pos], 4] = encoded
          end

          # Patch a data-address load with the blob's run-time address. The blob
          # sits at +position+ within @code, and ROM.assemble drops @code into the
          # cartridge right after the header, so its address is the cartridge base
          # plus the header plus that position.
          def resolve_data_address(fix)
            position = @data_positions.fetch(fix[:target]) do
              raise LoweringError, "reference to undefined data #{fix[:target].inspect}"
            end
            address = ROM_START + RubyGBA::ROM::ENTRY_OFFSET + position
            @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], address)
          end

          # Patch a load with a *code label's* run-time address — the same cartridge
          # math as a data blob (base + header + position), but the position comes from
          # the label table. Used to hand the interrupt vector the address of a routine
          # that lives in the code, not in the data region.
          def resolve_label_address(fix)
            position = @labels.fetch(fix[:target]) do
              raise LoweringError, "reference to undefined label #{fix[:target].inspect}"
            end
            address = ROM_START + RubyGBA::ROM::ENTRY_OFFSET + position
            @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], address)
          end

          # Load the run-time address of a named code label into +reg+ (a fixed-size
          # placeholder patched in the second pass, once the label's position is known).
          def emit_load_label_address(reg, label)
            @fixups << { pos: pos, kind: :label_addr, reg: reg, target: label }
            emit(ASM.load_immediate_fixed(reg, 0))
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
          # source, a sequencer's cursor) build on this.
          def emit_load_data_address(reg, name)
            @fixups << { pos: pos, kind: :data_addr, reg: reg, target: name }
            emit(ASM.load_immediate_fixed(reg, 0))
          end

          # A memory-mapped register / VRAM halfword write — the one ASM primitive
          # nearly every lowering concern reaches for, so it lives beside emit rather
          # than with the rest of Primitives.
          def write_reg16(address, value)
            emit(ASM.load_immediate(ACC, value))
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(ACC, TMP))
          end

          # Patch a fixed 16-byte placeholder in place — the shape every custom fixup
          # resolver (Placement's :fast_addr/:hot_size included) writes back with.
          def patch16(pos, bytes)
            @code[pos, 16] = bytes
          end
        end
      end
    end
  end
end
