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
          # each placeholder — a branch to a label, or a load of a blob's address.
          def resolve_fixups
            @fixups.each do |fix|
              fix[:kind] == :data_addr ? resolve_data_address(fix) : resolve_branch(fix)
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

          # Lay the embedded blobs out after all the code, remembering where each
          # landed so resolve_data_address can turn a name into an address. Data
          # after the code means the main flow never runs into it.
          def emit_data_region
            @data_blobs.each do |name, bytes|
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
