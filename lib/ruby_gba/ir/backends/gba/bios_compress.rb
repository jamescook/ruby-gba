# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Squeeze an embedded asset so it takes less room in the cartridge.
        #
        # Graphics — the tile pictures, the color tables, the maps — are the bulk of a
        # cart, and they hold a lot of repetition: flat areas of one color, a border
        # that repeats, a run of blank tiles. This module packs those bytes at build
        # time into one of the two formats the console's own boot ROM (the BIOS) knows
        # how to expand. At load, instead of copying the raw bytes into video memory,
        # the backend asks the BIOS to expand the packed bytes straight into that same
        # video-memory slot (see BiosDecompress in drawing.rb). The slot was going to
        # be filled anyway, so the only thing that changes is the cart got smaller —
        # nothing extra is kept in the console's scarce work RAM.
        #
        # Two schemes, both from the BIOS:
        #
        # - LZ77 (a sliding-window scheme): a run of bytes that appeared a little
        #   earlier is written as a short back-reference — "copy N bytes from D bytes
        #   back" — instead of the bytes themselves. Good for tile art, where the same
        #   little shapes and edges recur.
        # - RLE (run-length encoding): a byte repeated many times in a row is written
        #   once with a count. Good for palettes and maps with long flat stretches.
        #
        # Every packed blob starts with the 4-byte header the BIOS reads: the low byte
        # names the scheme (bits 4-7) and the next three bytes hold the size of the
        # expanded data. We try both schemes and keep whichever is smaller; if neither
        # actually shrinks the blob, we report `:none` and the backend keeps the plain
        # copy. So packing can only help — it never makes a blob bigger.
        #
        # This is purely how the GBA backend STORES its assets — a lowering concern, not
        # a program behavior. The program does the same thing either way; only the cart
        # gets smaller. So it lives here in the GBA lowering and nowhere else: the Ruby
        # interpreter reads the raw asset data directly and never sees a packed blob, so
        # it needs no part of this. (The expansion does cost a little CPU time the first
        # time an asset loads — a fraction of a frame per blob at the BIOS rate of a few
        # hundred KB per second. It lands at boot or on a scene change, under the blank
        # screen, exactly where real cartridges decompress their level data.)
        module BiosCompress
          module_function

          # LZ77 back-references: 3..18 bytes long (a 4-bit length field, plus 3), from
          # a window up to 4096 bytes back (a 12-bit distance). The nibble/bit layout
          # of the header and references below is the format the BIOS decoder expects.
          MIN_MATCH = 3
          MAX_MATCH = 18
          MAX_WINDOW = 4096

          TYPE_LZ77 = 1 # header scheme nibble for LZ77
          TYPE_RLE  = 3 # header scheme nibble for run-length

          # Pack +bytes+ with whichever scheme comes out smallest. Returns
          # [codec, blob] where codec is :lz77, :rle, or :none. For :lz77/:rle the blob
          # is the header + packed payload (padded to a whole number of 4-byte words,
          # which the BIOS wants). For :none nothing shrank it, so the blob is the
          # original bytes unchanged and the caller keeps its plain copy.
          def best(bytes)
            return [:none, bytes] if bytes.nil? || bytes.empty?

            candidates = [
              [:lz77, framed(lz77(bytes), TYPE_LZ77, bytes.bytesize)],
              [:rle,  framed(rle(bytes),  TYPE_RLE,  bytes.bytesize)],
            ]
            codec, blob = candidates.min_by { |_c, b| b.bytesize }
            blob.bytesize < bytes.bytesize ? [codec, blob] : [:none, bytes]
          end

          # Pack with LZ77. The output is a stream of groups; each group is one flag
          # byte followed by up to eight items. The flag's bits, read high bit first,
          # say for each item whether it is a literal byte (0) or a back-reference (1).
          def lz77(bytes)
            data = bytes.bytes
            n = data.length
            out = []
            pos = 0
            while pos < n
              flag_at = out.length
              out << 0 # reserve the flag byte; fill it in once the group is built
              flags = 0
              count = 0
              while count < 8 && pos < n
                length, distance = longest_match(data, pos, n)
                flags <<= 1
                if length >= MIN_MATCH
                  flags |= 1
                  encode_match(out, length, distance)
                  pos += length
                else
                  out << data[pos]
                  pos += 1
                end
                count += 1
              end
              # The decoder always reads the top bit first. If the group ran short at
              # the end of the data, shift the used bits up so the first item is the
              # high bit and the empty trailing items read as 0.
              out[flag_at] = (flags << (8 - count)) & 0xFF
            end
            out
          end

          # Pack with run-length encoding. A flag byte's top bit picks the run kind and
          # its low 7 bits carry the length: a compressed run (top bit set) is one byte
          # repeated 3..130 times; a literal run (top bit clear) is 1..128 bytes copied
          # as-is. Literals let incompressible stretches pass through with little cost.
          def rle(bytes)
            data = bytes.bytes
            n = data.length
            out = []
            i = 0
            while i < n
              run = run_length(data, i, n, 130)
              if run >= 3
                out << (0x80 | (run - 3))
                out << data[i]
                i += run
              else
                start = i
                length = 0
                # Gather literals until a compressible run (3+ of a kind) begins, or we
                # hit the 128-byte cap, or the data ends.
                while i < n && length < 128 && run_length(data, i, n, 3) < 3
                  i += 1
                  length += 1
                end
                out << (length - 1)
                out.concat(data[start, length])
              end
            end
            out
          end

          # Expand a packed blob back to its original bytes. This is the software mirror
          # of what the console's BIOS does at load. The backend does not call it — the
          # hardware decoder does the real work — but it lets a test pack a blob and
          # confirm it round-trips without booting an emulator.
          def decode(blob)
            b = blob.bytes
            type = (b[0] >> 4) & 0x0F
            size = b[1] | (b[2] << 8) | (b[3] << 16)
            payload = b[4..] || []
            case type
            when TYPE_LZ77 then decode_lz77(payload, size)
            when TYPE_RLE  then decode_rle(payload, size)
            end
          end

          # --- internals ---

          # The longest run of bytes at +pos+ that also appears earlier within the
          # window, returned as [length, distance]. Distance starts at 2 (never 1): the
          # BIOS routine that expands into video memory writes two bytes at a time, so a
          # reference to the single byte just written is unsafe. Keeping the nearest
          # distance at 2 makes every blob safe for that routine. length is 0 when no
          # run of at least MIN_MATCH is found.
          def longest_match(data, pos, n)
            best_len = 0
            best_dist = 0
            earliest = [0, pos - MAX_WINDOW].max
            start = pos - 2
            while start >= earliest
              length = 0
              length += 1 while length < MAX_MATCH && (pos + length) < n && data[start + length] == data[pos + length]
              if length > best_len
                best_len = length
                best_dist = pos - start
              end
              start -= 1
            end
            [best_len, best_dist]
          end

          # Write a back-reference as the two bytes the BIOS reads: the high nibble of
          # the first byte is (length - 3); the remaining 12 bits hold (distance - 1).
          def encode_match(out, length, distance)
            disp = distance - 1
            out << ((((length - 3) & 0x0F) << 4) | ((disp >> 8) & 0x0F))
            out << (disp & 0xFF)
          end

          # How many equal bytes start at +i+, capped at +cap+.
          def run_length(data, i, n, cap)
            run = 1
            run += 1 while (i + run) < n && run < cap && data[i + run] == data[i]
            run
          end

          # Prepend the 4-byte BIOS header and pad to a whole number of 4-byte words.
          def framed(payload, type, size)
            blob = [(type << 4), size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF]
            blob.concat(payload)
            blob << 0 while (blob.length % 4) != 0
            blob.pack("C*")
          end

          def decode_lz77(payload, size)
            out = []
            ip = 0
            while out.length < size
              flags = payload[ip]
              ip += 1
              8.times do
                break if out.length >= size

                if (flags & 0x80) != 0
                  b0 = payload[ip]
                  b1 = payload[ip + 1]
                  ip += 2
                  distance = (((b0 & 0x0F) << 8) | b1) + 1
                  length = (b0 >> 4) + 3
                  length.times { out << out[out.length - distance] }
                else
                  out << payload[ip]
                  ip += 1
                end
                flags = (flags << 1) & 0xFF
              end
            end
            out.pack("C*")
          end

          def decode_rle(payload, size)
            out = []
            ip = 0
            while out.length < size
              flag = payload[ip]
              ip += 1
              if (flag & 0x80) != 0
                run = (flag & 0x7F) + 3
                byte = payload[ip]
                ip += 1
                run.times { out << byte }
              else
                length = (flag & 0x7F) + 1
                length.times do
                  out << payload[ip]
                  ip += 1
                end
              end
            end
            out.pack("C*")
          end
        end
      end
    end
  end
end
