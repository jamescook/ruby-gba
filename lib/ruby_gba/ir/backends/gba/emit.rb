# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Low-level emitting and the two-pass label/branch fixup machinery.
        module Emit
          include Constants

          def emit(bytes)
            @code << bytes
          end

          # The current byte position — the program counter of the emit pass.
          def pos
            @code.bytesize
          end

          def place_label(name)
            @labels[name] = pos
          end

          def gensym
            "L#{@label_seq += 1}"
          end

          # Emit a 4-byte branch placeholder now and remember to resolve it against
          # +target+ later. kind is :b (unconditional), :bcond (conditional), or
          # :bl (call). The real branch is written in resolve_fixups.
          def emit_branch(kind, target, cond: nil)
            @fixups << { pos: pos, kind: kind, cond: cond, target: target }
            emit(ASM.nop)
          end

          # Second pass: every label and data-blob position is known now, so patch
          # each placeholder — a branch to a label, or a load of a blob's / label's address.
          def resolve_fixups
            @fixups.each do |fix|
              case fix[:kind]
              when :data_addr then resolve_data_address(fix)
              when :label_addr then resolve_label_address(fix)
              else resolve_branch(fix)
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
        end
      end
    end
  end
end
