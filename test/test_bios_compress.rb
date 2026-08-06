# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Storing assets packed in the cartridge. Tile pictures, palettes and maps hold a
# lot of repetition, so we pack them at build time and let the console's BIOS
# expand them into video memory at load — the cart gets smaller with nothing extra
# kept in work RAM. These tests cover the packer directly (it round-trips, it only
# ever shrinks, and its output is safe for the video-memory expander) and then boot
# a real ROM whose tiles are packed, to confirm the hardware expands them correctly.
class TestBiosCompress < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Pack = RubyGBA::IR::Backends::GBA::BiosCompress

  # --- The packer: pack then expand gives back the original bytes ---

  def assert_round_trips(bytes)
    codec, blob = Pack.best(bytes)
    skip "nothing to expand — best kept it raw" if codec == :none
    assert_equal bytes, Pack.decode(blob), "packed #{codec} blob did not expand to the original"
  end

  def test_a_run_of_one_byte_round_trips
    assert_round_trips(("\x07".b * 200))
  end

  def test_repeated_tile_art_round_trips
    # A little 8x8 shape (a diagonal) repeated many times — the kind of recurring
    # pattern LZ77 is built to fold.
    tile = (0...64).map { |i| ((i % 9).zero? ? 1 : 0) }.pack("C*")
    assert_round_trips(tile * 40)
  end

  def test_mixed_runs_and_literals_round_trip
    bytes = ("\x00".b * 50) + "abcdef".b + ("\xFF".b * 90) + "ghij".b + ("\x11".b * 30)
    assert_round_trips(bytes)
  end

  def test_lz77_round_trips_directly
    bytes = (("hello world " * 20)).b
    assert_equal bytes, Pack.decode(Pack.framed(Pack.lz77(bytes), Pack::TYPE_LZ77, bytes.bytesize))
  end

  def test_rle_round_trips_directly
    bytes = ("\x00".b * 300) + ("\xAB".b * 5)
    assert_equal bytes, Pack.decode(Pack.framed(Pack.rle(bytes), Pack::TYPE_RLE, bytes.bytesize))
  end

  # --- It only ever shrinks: incompressible or tiny data stays raw ---

  def test_repetitive_data_shrinks
    codec, blob = Pack.best("\x00".b * 500)
    refute_equal :none, codec, "a long run should pack"
    assert blob.bytesize < 500, "the packed blob (#{blob.bytesize} bytes) should be smaller than 500"
  end

  def test_incompressible_data_stays_raw
    # A short, varied blob has no runs to fold, so the 4-byte header alone would make
    # it bigger. best must decline and hand back the original for a plain copy.
    bytes = (0...24).map { |i| (i * 37) & 0xFF }.pack("C*")
    codec, blob = Pack.best(bytes)
    assert_equal :none, codec
    assert_equal bytes, blob
  end

  def test_empty_input_stays_raw
    assert_equal [:none, ""], Pack.best("")
  end

  # The 4-byte header plus 4-byte padding is an 8-byte floor, so nothing 8 bytes or
  # smaller can pack smaller — even an 8-byte run of one value.
  def test_eight_bytes_or_fewer_stay_raw
    codec, = Pack.best("\x00".b * 8)
    assert_equal :none, codec
  end

  def test_nine_identical_bytes_pack
    codec, blob = Pack.best("\x00".b * 9)
    refute_equal :none, codec, "9 identical bytes should pack below 9"
    assert_operator blob.bytesize, :<, 9
  end

  # --- The savings report: numbers and the one-line summary ---

  def test_human_bytes_formats_kb_and_bytes
    assert_equal "512 bytes", Pack.human_bytes(512)
    assert_equal "1 byte", Pack.human_bytes(1)
    assert_equal "1.0 KB", Pack.human_bytes(1024)
    assert_equal "2.5 KB", Pack.human_bytes(2560)
  end

  def test_report_summary_line_for_two_schemes
    r = Pack::Report.new(count: 2, raw_bytes: 20_480, packed_bytes: 5120, schemes: %i[lz77 rle])
    assert r.any?
    assert_equal 15_360, r.saved_bytes
    assert_equal 75, r.percent
    assert_equal "Packed 2 assets with LZ77 and RLE: 20.0 KB to 5.0 KB, saved 15.0 KB (75%)", r.summary_line
  end

  def test_report_summary_line_singular_one_scheme
    r = Pack::Report.new(count: 1, raw_bytes: 1024, packed_bytes: 512, schemes: %i[rle])
    assert_equal "Packed 1 asset with RLE: 1.0 KB to 512 bytes, saved 512 bytes (50%)", r.summary_line
  end

  def test_empty_report_shows_nothing
    r = Pack::Report.new(count: 0, raw_bytes: 0, packed_bytes: 0, schemes: [])
    refute r.any?
  end

  # --- The build records the packing report on the ROM (display is the CLI's job) ---

  def compressible_tiled
    RubyGBA.build("PACK", code: "BPAK", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:red_t, "#" => :red) { (["########"] * 8).join("\n") }
      tiles :set, "R" => :red_t
      background :bg, tiles: :set, map: Array.new(32) { "R" * 32 } # one tile everywhere: very packable
      game_loop do
        wait_vblank
        halt
      end
    end
  end

  def test_a_build_that_packs_keeps_the_numbers_on_the_rom
    rom = compressible_tiled
    assert rom.compression.any?, "the ROM should carry a non-empty compression report"
    assert_operator rom.compression.saved_bytes, :>, 0
    assert_match(/Packed \d+ assets? with (LZ77|RLE)/, rom.compression.summary_line)
  end

  def test_a_build_with_nothing_to_pack_has_an_empty_report
    rom = RubyGBA.build("PLAIN", code: "BPLN", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      clear_screen :black
      halt
    end
    refute rom.compression.any?
  end

  # --- Safe for the video-memory expander: no reference reaches back only one byte ---

  # The BIOS routine that expands into video memory writes two bytes at a time, so a
  # back-reference to the single byte just written is unsafe. The packer must never
  # emit one. Walk an LZ77 payload and collect every reference distance.
  def reference_distances(payload, size)
    distances = []
    out = 0
    ip = 0
    while out < size
      flags = payload[ip]
      ip += 1
      8.times do
        break if out >= size

        if (flags & 0x80) != 0
          b0 = payload[ip]
          b1 = payload[ip + 1]
          ip += 2
          distances << ((((b0 & 0x0F) << 8) | b1) + 1)
          out += (b0 >> 4) + 3
        else
          ip += 1
          out += 1
        end
        flags = (flags << 1) & 0xFF
      end
    end
    distances
  end

  def test_lz77_never_references_the_previous_byte
    bytes = ("\x2A".b * 400) # all identical: the tempting (unsafe) encoding is distance 1
    payload = Pack.lz77(bytes)
    distances = reference_distances(payload, bytes.bytesize)
    refute_empty distances, "an all-identical run should use back-references"
    assert_operator distances.min, :>=, 2, "no reference may reach back only one byte (video-memory unsafe)"
  end

  # --- Hardware: a packed tile block really expands through the BIOS and renders ---

  # A tiled background of solid 8x8 tiles: the shared tile block is long runs of one
  # palette index, and the 32x32 map is mostly one repeated tile — both pack well, so
  # the backend uploads them with the BIOS expander instead of a plain copy.
  def solid_board
    solid8 = (["########"] * 8).join("\n")
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:red_t,  "#" => :red)  { solid8 }
      image(:blue_t, "#" => :blue) { solid8 }
      tiles :set, "R" => :red_t, "B" => :blue_t
      background :board, tiles: :set, map: Array.new(32) { |r| (0...32).map { |c| ((r + c).even? ? "R" : "B") }.join }
      game_loop do
        wait_vblank
        halt
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_the_backend_packs_the_tile_block
    gba = GBA.new
    gba.lower(solid_board)
    codecs = gba.instance_variable_get(:@blob_codecs).values
    assert(codecs.any? { |c| %i[lz77 rle].include?(c) },
           "at least one video-memory blob should pack (got #{codecs.inspect})")
  end

  def test_a_packed_board_renders_on_the_console
    rom = ROM.assemble(GBA.new.lower(solid_board), title: "PACKED", code: "BPAK", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    # Cell (0,0)=R, (1,0)=B, (0,1)=B — a checker, expanded from the packed tile block.
    assert v.red?(1, 1),  "cell (0,0) is red, got 0x#{format('%04X', v.pixel_gba(1, 1))}"
    assert v.blue?(9, 1), "cell (1,0) is blue, got 0x#{format('%04X', v.pixel_gba(9, 1))}"
    assert v.blue?(1, 9), "cell (0,1) is blue, got 0x#{format('%04X', v.pixel_gba(1, 9))}"
  end

  # --- Finding the longest match: chains must agree with a full scan ---
  #
  # LZ77 packs a blob by asking, for every byte, "has this run of bytes appeared
  # already?" The honest way to answer is to try every earlier position in the
  # 4096-byte window, which costs the size of the window for every byte of every
  # asset. Instead each position is linked to the previous one starting with the
  # same MIN_MATCH bytes, and only that chain is walked — any run worth encoding
  # begins with those bytes, so nothing is missed.
  #
  # "Nothing is missed" is the whole claim, and these prove it the only way worth
  # trusting: run the exhaustive search alongside and require the same answer.

  # The exhaustive search, written out plainly as the thing to agree with.
  def full_scan_match(data, pos, n)
    best_len = 0
    best_dist = 0
    earliest = [0, pos - Pack::MAX_WINDOW].max
    start = pos - 2 # distance 1 is unsafe for the video-memory expander
    while start >= earliest
      length = 0
      length += 1 while length < Pack::MAX_MATCH && (pos + length) < n &&
                        data[start + length] == data[pos + length]
      if length > best_len
        best_len = length
        best_dist = pos - start
      end
      start -= 1
    end
    [best_len, best_dist]
  end

  # Compare the two searches at every position. Report the first disagreement
  # rather than asserting per byte — one assertion for the claim, and a message
  # that names the byte to go and look at.
  def assert_finds_the_same_matches(blob, what)
    data = blob.bytes
    n = data.length
    chains = Pack.match_chains(data, n)

    disagreement = nil
    (0...n).each do |pos|
      chained = Pack.longest_match(data, pos, n, chains)
      exhaustive = full_scan_match(data, pos, n)
      # Below MIN_MATCH nothing is written as a back-reference, so the two only
      # have to agree on runs long enough to be encoded.
      next if chained.first < Pack::MIN_MATCH && exhaustive.first < Pack::MIN_MATCH
      next if chained == exhaustive

      disagreement = "at byte #{pos} of #{n} the chain found [length, distance] " \
                     "#{chained.inspect} where a full scan of the window finds #{exhaustive.inspect}"
      break
    end

    assert_nil disagreement, "#{what}: #{disagreement}"
  end

  # A byte string from a fixed seed — random-looking but the same on every run, so
  # a failure is always reproducible.
  def seeded(size, seed, &pick)
    rng = Random.new(seed)
    (0...size).map { pick.call(rng) }.pack("C*")
  end

  def test_the_chain_matches_a_full_scan_on_incompressible_data
    # Nothing repeats, so almost every position must come back empty-handed — the
    # case where a chain could wrongly stop early.
    assert_finds_the_same_matches(seeded(800, 99) { |r| r.rand(256) }, "incompressible")
  end

  def test_the_chain_matches_a_full_scan_on_tile_art
    # Mostly transparent with flecks of colour: long runs, and many positions
    # sharing the same opening bytes. The shape real sprite art has.
    assert_finds_the_same_matches(
      seeded(800, 1234) { |r| r.rand(10).zero? ? r.rand(1..15) : 0 }, "tile art"
    )
  end

  def test_the_chain_matches_a_full_scan_on_one_repeated_byte
    # Every position opens with the same bytes, so the chain holds every earlier
    # position — the longest chain there can be.
    assert_finds_the_same_matches(("\x00".b * 400), "one repeated byte")
  end

  def test_the_chain_matches_a_full_scan_on_a_short_repeating_pattern
    assert_finds_the_same_matches(("abcabd".b * 100), "a repeating pattern")
  end

  # A back-reference carries its distance in 12 bits, so it can only reach
  # MAX_WINDOW bytes back. A match further away than that must be ignored, however
  # good it looks: encoding it would write a distance the field cannot hold, and the
  # console would expand the asset into garbage.
  #
  # This needs data built for the purpose. In ordinary art some match is nearly
  # always available nearby, so the search never looks far enough for the limit to
  # matter, and a test on realistic bytes passes whether the limit is applied or
  # not. So: one distinctive run at the very start, filler past the window's width
  # that shares none of its bytes, then the same run again — the only match for the
  # second run is the first, and it is out of reach.
  def test_a_match_beyond_the_window_is_not_used
    marker = "ZYXWVUTSRQPONMLKJI".b # MAX_MATCH bytes, none of which appear in the filler
    filler = seeded(Pack::MAX_WINDOW + 200, 7) { |r| r.rand(1..15) }
    blob = marker + filler + marker
    second = marker.bytesize + filler.bytesize
    data = blob.bytes
    assert_operator second, :>, Pack::MAX_WINDOW, "the repeat has to be out of reach to test anything"

    length, distance = Pack.longest_match(data, second, data.length, Pack.match_chains(data, data.length))
    assert_operator length, :<, Pack::MIN_MATCH,
                    "the only match is #{second} bytes back, past the #{Pack::MAX_WINDOW}-byte " \
                    "reach of a back-reference, so nothing can be encoded here"
  end

  # And the rule that makes the one above matter: whatever the packer chooses, the
  # distance always fits the field it is written into.
  def test_every_match_it_finds_is_within_reach
    blob = seeded(Pack::MAX_WINDOW + 800, 11) { |r| r.rand(6).zero? ? r.rand(1..15) : 0 }
    data = blob.bytes
    n = data.length
    chains = Pack.match_chains(data, n)

    out_of_reach = nil
    (0...n).each do |pos|
      length, distance = Pack.longest_match(data, pos, n, chains)
      next if length < Pack::MIN_MATCH
      next if (2..Pack::MAX_WINDOW).cover?(distance)

      out_of_reach = "at byte #{pos} the match is #{distance} back, which does not fit a back-reference"
      break
    end

    assert_nil out_of_reach, out_of_reach
  end

  # Not a benchmark — a guard against the chains being replaced by the exhaustive
  # search again. Packing this blob takes a few tens of milliseconds; a full scan of
  # the window for every byte takes several SECONDS, so the bound below is roughly a
  # hundred times the real cost and still catches that decisively.
  def test_packing_a_large_asset_does_not_scan_the_whole_window_per_byte
    blob = seeded(16_000, 99) { |r| r.rand(256) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Pack.best(blob)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0,
                    "packing #{blob.bytesize} bytes took #{elapsed.round(2)}s — that is the cost of " \
                    "searching the whole window for every byte, so the match chains are not being used"
  end
end
