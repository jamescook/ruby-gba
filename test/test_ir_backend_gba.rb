# frozen_string_literal: true

require "test_helper"

# The GBA backend: lower hand-built IR programs to a real ROM. The deterministic
# tests check the two-pass jump resolution and that the ROM finalizes cleanly;
# the gemba-backed tests actually run the ROM and read pixels off the screen (and
# skip when gemba isn't installed).
class TestIRBackendGBA < Minitest::Test
  include RubyGBA::IR::Build

  # Lower a program to machine code, then assemble it into a runnable ROM.
  def lower(program)
    RubyGBA::ROM.assemble(GBA.new.lower(program), title: "IRLOWER", code: "IRLO", maker: "98")
  end

  # Decode the branch/call word at byte +at+ back into the target byte offset it
  # jumps to — the inverse of how ASM encodes a PC-relative branch.
  def branch_target(code, at)
    word = code[at, 4].unpack1("V")
    off = word & 0x00FFFFFF
    off -= 0x0100_0000 if off >= 0x0080_0000 # sign-extend the 24-bit field
    at + (off + 2) * 4
  end

  # ---- two-pass label / forward-reference resolution ----

  def test_forward_call_resolves_to_the_func_entry
    # `inc` is called before it's defined later in the program.
    gba = GBA.new
    gba.lower(program(
      call(:inc),
      halt,
      func(:inc, set(:x, 1)),
    ))

    # The WAITCNT boot setup (6 instructions = 24 bytes) is emitted first, then the
    # program, so the forward call's BL lands just past that prologue.
    call_off = 24
    bl = gba.code[call_off, 4].unpack1("V")
    assert_equal 0xEB, bl >> 24, "the forward call lowers to a BL"
    assert_equal gba.labels["func_inc"], branch_target(gba.code, call_off)
  end

  def test_loop_branches_backward_to_its_top
    gba = GBA.new
    gba.lower(program(loop_(add(:x, 1))))
    # The last instruction is the unconditional jump back to the loop top.
    last = gba.code.bytesize - 4
    assert_operator branch_target(gba.code, last), :<, last, "loop must jump backward"
  end

  def test_call_to_undefined_func_raises
    assert_raises(GBA::LoweringError) { lower(program(call(:ghost), halt)) }
  end

  def test_raw_bytes_are_appended_verbatim
    # The escape hatch: a raw node's bytes land in the code exactly as given.
    bytes = "\x00\xF0\x20\xE3".b # an arbitrary 4-byte ARM word
    gba = GBA.new
    gba.lower(program(raw(bytes)))
    assert_equal bytes, gba.code[0, bytes.bytesize]
  end

  # ---- the ROM is well-formed (the ROM validator runs inside finalize!) ----

  def test_a_drawing_program_finalizes_into_a_valid_rom
    rom = lower(program(screen(:bitmap), clear_screen(:blue), halt))
    assert_instance_of RubyGBA::ROM, rom
    assert_operator rom.size, :>, 0xC0
  end

  # ---- it actually runs and draws (gemba; skips when absent) ----

  def test_clear_screen_fills_the_whole_screen
    rom = lower(program(screen(:bitmap), clear_screen(:blue), halt))
    v = assert_gemba_loads_rom(rom, frames: 5)
    assert v.blue?(0, 0)
    assert v.blue?(239, 159)
  end

  def test_a_constant_pixel_lands_at_its_coordinates
    rom = lower(program(screen(:bitmap), clear_screen(:black), pixel(10, 20, :red), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 20)
    assert v.black?(11, 20)
  end

  def test_fill_rect_paints_its_block
    rom = lower(program(screen(:bitmap), clear_screen(:black), fill_rect(5, 5, 4, 3, :green), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.green?(5, 5)
    assert v.green?(8, 7)  # bottom-right corner (5+4-1, 5+3-1)
    assert v.black?(9, 5)  # just outside
  end

  def test_arithmetic_drives_a_computed_pixel_coordinate
    # x = 5 + 5 = 10, then plot at (x, 0): proves variables + arithmetic + a
    # runtime-computed VRAM address all lower correctly.
    rom = lower(program(
      screen(:bitmap),
      clear_screen(:black),
      set(:x, 5),
      add(:x, 5),
      pixel(:x, 0, :red),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 0)
    assert v.black?(9, 0)
  end

  def test_loop_and_conditional_draw_a_row_then_halt
    # Draw red pixels at x = 1..5 then stop; (6,0) must stay black.
    rom = lower(program(
      screen(:bitmap),
      clear_screen(:black),
      set(:x, 0),
      loop_(
        add(:x, 1),
        pixel(:x, 0, :red),
        if_(binop(:>=, var_ref(:x), int(5)), halt),
      ),
    ))
    v = assert_gemba_loads_rom(rom, frames: 5)
    assert v.red?(1, 0)
    assert v.red?(5, 0)
    assert v.black?(6, 0)
  end

  def test_held_input_gates_a_draw
    # With no button pressed, held(:a) is false, so the pixel must not appear.
    rom = lower(program(
      screen(:bitmap),
      clear_screen(:black),
      if_(held(:a), pixel(10, 10, :red)),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.black?(10, 10)
  end

  KEY_START = RubyGBA::Constants::KEY_START

  def test_pressed_program_lowers_to_a_valid_rom
    rom = lower(program(
      screen(:bitmap),
      loop_(wait_vblank, if_(pressed(:start), pixel(10, 10, :red))),
    ))
    assert_instance_of RubyGBA::ROM, rom
  end

  def test_pressed_does_not_fire_without_input
    rom = lower(program(
      screen(:bitmap),
      clear_screen(:black),
      loop_(wait_vblank, if_(pressed(:start), pixel(10, 10, :red))),
    ))
    v = assert_gemba_loads_rom(rom, frames: 5)
    assert v.black?(10, 10)
  end

  def test_pressed_fires_once_on_the_down_edge
    # Each fresh press advances :count, and we plot a pixel at (count, 0). Holding
    # start across many frames must advance count by exactly one — pressed is the
    # edge, not the level — so the pixel lands at (1, 0), never (2, 0).
    rom = lower(program(
      screen(:bitmap),
      set(:count, 0),
      loop_(
        wait_vblank,
        if_(pressed(:start), add(:count, 1)),
        clear_screen(:black),
        pixel(:count, 0, :red),
      ),
    ))

    v = assert_gemba_loads_rom(rom, frames: 6, keys: KEY_START) # start held every frame
    assert v.red?(1, 0), "one down-edge => count == 1 => pixel at (1, 0)"
    assert v.black?(2, 0), "holding must not count as repeated presses"
  end

  def test_blit_copies_a_bitmap_to_the_screen
    # Per-row DMA copies the four pixels from ROM to VRAM at (10, 20). Raw BGR555:
    # red 0x001F, green 0x03E0, blue 0x7C00, white 0x7FFF.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      bitmap(:quad, width: 2, height: 2, pixels: [0x001F, 0x03E0, 0x7C00, 0x7FFF].pack("v*")),
      blit(:quad, 10, 20),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 20)
    assert v.green?(11, 20)
    assert v.blue?(10, 21)
    assert v.white?(11, 21)
    assert v.black?(12, 20) # just outside
  end

  def test_blit_honors_transparency
    # A 3-wide sprite: middle red, ends transparent, over a blue field. The blue
    # must show through the transparent ends.
    clear = 0x8000 # the transparent marker (bit 15, no real color uses it)
    rom = lower(program(
      screen(:bitmap), clear_screen(:blue),
      bitmap(:dot, width: 3, height: 1, pixels: [clear, 0x001F, clear].pack("v*"), transparent: clear),
      blit(:dot, 10, 10),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.blue?(10, 10), "transparent end -> background shows"
    assert v.red?(11, 10),  "lit pixel drawn"
    assert v.blue?(12, 10), "transparent end -> background shows"
  end

  def test_blit_follows_a_variable_position
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      bitmap(:dot, width: 1, height: 1, pixels: [0x001F].pack("v*")),
      set(:px, 100), set(:py, 50),
      blit(:dot, var_ref(:px), var_ref(:py)),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(100, 50)
    assert v.black?(99, 50)
  end

  def test_bitmap_pixels_land_in_the_code
    # A bitmap embeds its pixels in the data region, like a raw blob.
    gba = GBA.new
    gba.lower(program(bitmap(:friend, width: 2, height: 1, pixels: "\xDE\xAD\xBE\xEF".b), halt))
    assert_includes gba.code, "\xDE\xAD\xBE\xEF".b
  end

  def test_embedded_data_bytes_land_in_the_code
    # Deterministic: the blob's bytes are appended to the emitted code (the data
    # region), so they ship in the ROM.
    gba = GBA.new
    gba.lower(program(data(:blob, "\xDE\xAD\xBE\xEF".b), halt))
    assert_includes gba.code, "\xDE\xAD\xBE\xEF".b
  end

  def test_embedded_blobs_stay_word_aligned_after_an_odd_length_one
    # Blobs are DMA'd into palette / VRAM / sound memory, whose source address must
    # be aligned. An odd-length blob (an 8-bit sample of odd length, say) must not
    # push the blobs after it onto odd addresses — a misaligned palette DMA reads a
    # byte out of step and tints the whole screen wrong. Every blob starts on a word
    # boundary regardless of what preceded it. (Addresses are ROM base + 0xC0 header
    # + position, and 0xC0 is word-aligned, so an aligned position is an aligned
    # address.)
    gba = GBA.new
    gba.lower(program(data(:odd, "\x01\x02\x03".b), data(:after, "\xAA\xBB\xCC\xDD".b), halt))
    positions = gba.instance_variable_get(:@data_positions)
    positions.each do |name, pos|
      assert_equal 0, pos % 4, "data blob #{name.inspect} sits at byte #{pos}, not a word boundary"
    end
  end

  def test_a_byte_from_embedded_data_drives_a_pixel
    # The whole chain on hardware: blob in ROM -> address fixup resolved -> byte
    # read at run time -> used as a pixel's x. The byte is 10, so red lands at x=10.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      data(:coords, "\x0a".b),
      pixel(data_byte(:coords, 0), 0, :red),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 0)
    assert v.black?(11, 0)
  end

  def test_division_drives_a_computed_coordinate
    # x / 3 = 6; plot at (6, 0). The ARM7TDMI can't divide, so this exercises the
    # BIOS Div call in the lowering — and proves the emulator's BIOS runs it.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      set(:x, 20),
      pixel(binop(:/, var_ref(:x), int(3)), 0, :red),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(6, 0)
    assert v.black?(7, 0)
  end

  def test_and_gates_a_draw_on_both_conditions
    # x = 5 is in (1, 9): the AND holds and red draws. The second AND needs x > 9,
    # which fails, so blue stays away — proving both sides are actually combined.
    in_range = binop(:and, binop(:>, var_ref(:x), int(1)), binop(:<, var_ref(:x), int(9)))
    too_high = binop(:and, binop(:>, var_ref(:x), int(1)), binop(:>, var_ref(:x), int(9)))

    rom = lower(program(
      screen(:bitmap), clear_screen(:black), set(:x, 5),
      if_(in_range, pixel(10, 10, :red)),
      if_(too_high, pixel(20, 20, :blue)),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 10), "5 is >1 and <9, so the AND holds"
    assert v.black?(20, 20), "5 is not >9, so the AND fails"
  end

  def test_if_else_draws_the_else_branch_when_false
    # x = 1, so (x > 5) is false: the else-branch runs and draws blue, not red.
    taken = if_(binop(:>, var_ref(:x), int(5)), pixel(10, 10, :red))
    taken[:else] = else_(pixel(20, 20, :blue))

    rom = lower(program(screen(:bitmap), clear_screen(:black), set(:x, 1), taken, halt))
    v = assert_gemba_loads_rom(rom)
    assert v.blue?(20, 20), "false condition runs the else-branch"
    assert v.black?(10, 10), "the then-branch must not run"
  end

  # ---- abs / negate_abs (observed by driving a pixel coordinate) ----

  def test_abs_makes_a_negative_value_positive
    # v = -5, abs -> 5; plotting at (v, 0) lands at x=5. If abs left it negative
    # the coordinate would clip off-screen and nothing would appear at (5, 0).
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      set(:v, 5), negate(:v), abs(:v),
      pixel(:v, 0, :red), halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(5, 0)
    assert v.black?(4, 0)
  end

  def test_negate_abs_leaves_an_already_negative_value
    # v = -6, negate_abs -> still -6 (not +6); +20 brings it on-screen at 14.
    # A wrong flip to +6 would put the pixel at 26 instead.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      set(:v, 6), negate(:v), negate_abs(:v), add(:v, 20),
      pixel(:v, 0, :red), halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(14, 0)
    assert v.black?(26, 0)
  end

  # ---- extended draws: dma_fill_rect / draw_rect_at / draw_text ----

  def test_dma_fill_rect_paints_its_block
    rom = lower(program(screen(:bitmap), clear_screen(:black),
                        dma_fill_rect(4, 6, 4, 2, :red), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(4, 6)
    assert v.red?(7, 7)   # bottom-right (4+4-1, 6+2-1)
    assert v.black?(8, 6) # just outside
  end

  def test_draw_rect_at_paints_at_a_runtime_position
    # The rectangle's position comes from variables computed at run time.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      set(:x, 30), set(:y, 40),
      draw_rect_at(:x, :y, 4, 4, :green),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.green?(30, 40)
    assert v.green?(33, 43) # bottom-right corner
    assert v.black?(34, 40) # just outside
  end

  def test_draw_rect_at_follows_a_computed_coordinate
    # x = 10 + 10 = 20: proves the destination address is built from the live
    # value, not baked in at build time.
    rom = lower(program(
      screen(:bitmap), clear_screen(:black),
      set(:x, 10), add(:x, 10),
      draw_rect_at(:x, 50, 4, 4, :white),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.white?(20, 50)
    assert v.black?(19, 50)
  end

  def test_draw_text_renders_glyphs
    rom = lower(program(screen(:bitmap), clear_screen(:black),
                        draw_text("HI", 40, 30, :white), halt))
    v = assert_gemba_loads_rom(rom)
    # 'H' row 0 = 0x11: leftmost and rightmost columns lit, middle not.
    assert v.white?(40, 30)      # left post of 'H'
    assert v.white?(44, 30)      # right post of 'H'
    assert v.black?(42, 30)      # gap between the posts
  end

  def test_odd_width_dma_fill_is_a_friendly_error
    err = assert_raises(GBA::LoweringError) do
      lower(program(screen(:bitmap), dma_fill_rect(0, 0, 3, 2, :red), halt))
    end
    assert_match(/even/, err.message)
  end

  # ---- sound: lower it, then read the audio that actually came out ----
  # The exact register values are pinned by the pure-function tests in
  # test_sound_module.rb (shared with the legacy emitter). These prove the
  # lowered ROM really drives the hardware to make (or not make) sound.

  def test_a_lowered_beep_actually_plays_sound
    rom = lower(program(enable_sound, beep(:high), halt))
    v = assert_gemba_loads_rom(rom, frames: 8)
    assert v.sound?, "an enabled beep should produce audible PCM"
  end

  def test_a_lowered_noise_hit_actually_plays_sound
    rom = lower(program(enable_sound, noise(:explosion), halt))
    v = assert_gemba_loads_rom(rom, frames: 8)
    assert v.sound?, "an enabled noise hit should produce audible PCM on channel 4"
  end

  def test_a_lowered_wave_tone_actually_plays_sound
    rom = lower(program(enable_sound, wave(shape: :triangle, frequency: 262, volume: :full), halt))
    v = assert_gemba_loads_rom(rom, frames: 8)
    assert v.sound?, "an enabled wave tone should produce audible PCM on channel 3"
  end

  def test_enabling_sound_without_a_beep_stays_silent
    rom = lower(program(enable_sound, halt))
    v = assert_gemba_loads_rom(rom, frames: 8)
    assert v.silent?, "no beep means no sound"
  end

  def test_play_song_drives_the_music_channel
    rom = lower(program(
      screen(:bitmap),
      enable_sound,
      song(:tune, events: [[1, 262], [2, 330], [3, 392]], total_frames: 8),
      loop_(wait_vblank, play_song(:tune)),
    ))
    v = assert_gemba_loads_rom(rom, frames: 10)
    assert v.sound?, "play_song should trigger notes on the music channel"
  end

  # A song whose only note is on frame 0 — the downbeat. If the sequencer skipped
  # frame 0 (advancing its counter before comparing), this ROM would be silent
  # forever; hearing anything proves the first note actually plays on hardware.
  def test_play_song_plays_the_note_on_frame_zero
    rom = lower(program(
      screen(:bitmap),
      enable_sound,
      song(:downbeat, events: [[0, 262]], total_frames: 8),
      loop_(wait_vblank, play_song(:downbeat)),
    ))
    v = assert_gemba_loads_rom(rom, frames: 10)
    assert v.sound?, "the note on frame 0 should sound"
  end

  # A two-part song lowers each part onto its own square-wave channel; both are
  # driven, so the ROM makes sound.
  def test_play_song_lowers_a_layered_two_part_song
    rom = lower(program(
      screen(:bitmap),
      enable_sound,
      song(:duet, total_frames: 4, voices: [
        { events: [[0, 523], [2, 587]], duty: :half, volume: 12 },
        { events: [[0, 131]], duty: :half, volume: 8 },
      ]),
      loop_(wait_vblank, play_song(:duet)),
    ))
    v = assert_gemba_loads_rom(rom, frames: 10)
    assert v.sound?, "a two-part song should drive the music channels"
  end

  def test_play_song_for_an_undefined_song_is_a_lowering_error
    assert_raises(GBA::LoweringError) do
      lower(program(enable_sound, play_song(:ghost), halt))
    end
  end

  def test_case_var_dispatches_to_the_active_scene
    # state == 1 -> the :playing scene draws blue; :title (state 0) draws red.
    rom = lower(program(
      screen(:bitmap),
      clear_screen(:black),
      set(:state, 1),
      case_(:state, 0 => :title, 1 => :playing),
      halt,
      func(:title, pixel(10, 10, :red)),
      func(:playing, pixel(20, 20, :blue)),
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.blue?(20, 20), "state == 1 should run the :playing scene"
    assert v.black?(10, 10), "the :title scene must not run"
  end
end
