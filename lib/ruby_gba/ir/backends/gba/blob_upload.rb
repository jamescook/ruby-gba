# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # COPYING DATA OUT OF THE CARTRIDGE INTO THE CONSOLE'S MEMORY — the colour tables, the
        # tile pictures, the maps, the sprites' pictures. The cartridge holds them and the
        # display can only read them from its own memory, so every one is copied across
        # before it is shown, by the console's copying engine (DMA) or, where packing the
        # data made the cartridge smaller, by the console's built-in routine that unpacks it
        # straight into place.
        #
        # +codecs+ and +raw_bytes+ are the build's own tables of how each piece of data was
        # packed and how big it was before, which the build report reads.
        class BlobUpload
          include Console::Hardware
          include EmitterCalls

          def initialize(emitter:, primitives:, codecs:, raw_bytes:)
            @emitter = emitter
            @primitives = primitives
            @codecs = codecs
            @raw_bytes = raw_bytes
          end

          # Fill a fixed video-memory slot from an embedded blob at startup. This is the
          # one seam every tile upload goes through, so it is also where packing pays
          # off: try to pack the blob first, and if that shrank the cart, expand it into
          # the slot with the BIOS instead of copying it. Either way the slot ends up
          # holding the same bytes; only the size of the cart changes.
          def emit_dma_blob(blob_name, dest, units)
            case pack_blob(blob_name)
            when :lz77 then emit_bios_decompress(blob_name, dest, SWI_LZ77_VRAM)
            when :rle  then emit_bios_decompress(blob_name, dest, SWI_RLE_VRAM)
            else emit_plain_dma_blob(blob_name, dest, units)
            end
          end

          # One DMA of +units+ 16-bit words from an embedded blob to a fixed address,
          # both ends advancing — the same shape as the palette upload. Fills palette
          # and video memory at startup.
          def emit_plain_dma_blob(blob_name, dest, units)
            emit_load_data_address(ACC, blob_name)
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP)) # DMA source = the blob in the cartridge
            store_word_immediate(dest, REG_DMA3DAD)
            store_word_immediate(units | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
          end

          # BIOS decompression routines that expand two bytes at a time. Every slot we
          # fill this way — video memory, the palettes, the tile maps — rejects a single
          # byte write, so we always use the 16-bit variants. The routine number rides
          # in bits 16-23 of the SWI instruction (the ARM software-interrupt encoding).
          SWI_LZ77_VRAM = 0x12
          SWI_RLE_VRAM  = 0x15

          # Ask the BIOS to expand a packed blob straight into +dest+. r0 points at the
          # packed source (its 4-byte header first), r1 at the destination; the routine
          # reads the expanded size from the header, so there is no length to pass.
          def emit_bios_decompress(blob_name, dest, swi_number)
            emit_load_data_address(0, blob_name)   # r0 = packed source in the cartridge
            emit(ASM.load_immediate(1, dest))      # r1 = destination slot
            emit(ASM.swi(swi_number << 16))
          end

          # Pack a blob the first time we are about to upload it, and remember the
          # result so a later upload of the same blob (a scene re-entered) reuses it
          # instead of packing again. Returns the codec (:lz77/:rle/:none). When a
          # scheme shrinks the blob, the packed bytes replace the raw ones in place, so
          # the data region lays down the smaller version.
          def pack_blob(blob_name)
            return @codecs[blob_name] if @codecs.key?(blob_name)

            raw = @emitter.data_blobs[blob_name]
            codec, blob = BiosCompress.pack_smallest(raw)
            unless codec == :none
              @raw_bytes[blob_name] = raw.bytesize # remember the before size for the savings line
              @emitter.data_blobs[blob_name] = blob
            end
            @codecs[blob_name] = codec
          end
        end
      end
    end
  end
end
