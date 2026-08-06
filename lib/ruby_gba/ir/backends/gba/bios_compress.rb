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
        # gets smaller. So it lives here in the GBA lowering and nowhere else: the
        # reference interpreter reads the raw asset data directly and never sees a
        # packed blob, so
        # it needs no part of this. (The expansion does cost a little CPU time the first
        # time an asset loads — a fraction of a frame per blob at the BIOS rate of a few
        # hundred KB per second. It lands at boot or on a scene change, under the blank
        # screen, exactly where real cartridges decompress their level data.)
        module BiosCompress
          # Display names for the schemes, and a summary of one build's packing that the
          # build can print and a caller can read off the ROM. The numbers are exact —
          # measured at build time from the raw and packed byte counts, not estimated.
          SCHEME_NAMES = { lz77: "LZ77", rle: "RLE" }.freeze

          Report = Data.define(:count, :raw_bytes, :packed_bytes, :schemes) do
            # True when the build packed at least one asset (so there is a line to show).
            def any?
              count.positive?
            end

            def saved_bytes
              raw_bytes - packed_bytes
            end

            # How much smaller the packed assets are, as a whole-number percent.
            def percent
              raw_bytes.zero? ? 0 : ((saved_bytes * 100.0) / raw_bytes).round
            end

            # One concise, scannable build line: how many assets, the schemes used, and
            # the measured saving. For example:
            #   "Packed 3 assets with LZ77 and RLE: 14.0 KB to 6.0 KB, saved 8.0 KB (57%)"
            def summary_line
              "Packed #{count} #{count == 1 ? 'asset' : 'assets'} with #{scheme_list}: " \
                "#{BiosCompress.human_bytes(raw_bytes)} to #{BiosCompress.human_bytes(packed_bytes)}, " \
                "saved #{BiosCompress.human_bytes(saved_bytes)} (#{percent}%)"
            end

            # The schemes as words: "LZ77", or "LZ77 and RLE".
            def scheme_list
              schemes.map { |s| SCHEME_NAMES.fetch(s, s.to_s) }.join(" and ")
            end
          end

          module_function

          # A byte count for people: kilobytes with one decimal once it reaches 1 KB,
          # plain bytes below that. (1 KB = 1024 bytes, as memory is measured.)
          def human_bytes(n)
            n >= 1024 ? format("%.1f KB", n / 1024.0) : "#{n} #{n == 1 ? 'byte' : 'bytes'}"
          end

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
            # The packed form is a 4-byte BIOS header plus the payload, padded to a
            # 4-byte multiple — an 8-byte floor. So a blob of 8 bytes or fewer can never
            # come out smaller; skip the work and keep it raw. (Bigger blobs still fall
            # back to raw at the end when packing does not actually shrink them.)
            return [:none, bytes] if bytes.nil? || bytes.bytesize <= 8

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
            previous = match_chains(data, n)
            out = []
            pos = 0
            while pos < n
              flag_at = out.length
              out << 0 # reserve the flag byte; fill it in once the group is built
              flags = 0
              count = 0
              while count < 8 && pos < n
                length, distance = longest_match(data, pos, n, previous)
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
          def longest_match(data, pos, n, previous)
            # The longest a match here could possibly be: the format's cap, or what is
            # left of the data, whichever comes first. Too little left to reach
            # MIN_MATCH and no back-reference can qualify at all.
            limit = MAX_MATCH
            limit = n - pos if (n - pos) < limit
            return [0, 0] if limit < MIN_MATCH

            best_len = 0
            best_dist = 0
            earliest = pos - MAX_WINDOW
            earliest = 0 if earliest < 0

            # Walk only the places that begin with the same MIN_MATCH bytes, nearest
            # first. Any match long enough to be worth encoding starts with those
            # bytes, so nothing is missed by skipping the rest of the window.
            start = previous[pos]
            while start && start >= earliest
              if (pos - start) >= 2 # distance 1 is unsafe — see above
                length = 0
                length += 1 while length < limit && data[start + length] == data[pos + length]
                if length > best_len
                  best_len = length
                  best_dist = pos - start
                  # Nothing further back can beat this, and ties go to the nearest
                  # match, which we already have — so the rest of the chain cannot
                  # change the answer.
                  break if best_len == limit
                end
              end
              start = previous[start]
            end
            [best_len, best_dist]
          end

          # For every position, the nearest earlier position that starts with the same
          # MIN_MATCH bytes — or nil when there is none. Following the links from a
          # position walks its candidate matches nearest-first, which is the order that
          # decides ties, so the packed bytes come out the same as a full scan of the
          # window would give. Building it is one pass; it replaces a search that
          # re-read up to 4096 earlier positions for EVERY byte of every asset.
          def match_chains(data, n)
            previous = Array.new(n)
            latest = {}
            last = n - MIN_MATCH
            i = 0
            while i <= last
              key = 0
              MIN_MATCH.times { |k| key = (key << 8) | data[i + k] }
              previous[i] = latest[key]
              latest[key] = i
              i += 1
            end
            previous
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
