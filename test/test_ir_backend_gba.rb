# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The GBA backend: lower hand-built IR programs to a real ROM. The deterministic
# tests check the two-pass jump resolution and that the ROM finalizes cleanly;
# the gemba-backed tests actually run the ROM and read pixels off the screen (and
# skip when gemba isn't installed).
class TestIRBackendGBA < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  GBA = RubyGBA::IR::Backends::GBA

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

    bl = gba.code[0, 4].unpack1("V")
    assert_equal 0xEB, bl >> 24, "first instruction should be a BL (call)"
    assert_equal gba.labels["func_inc"], branch_target(gba.code, 0)
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

  # ---- the ROM is well-formed (Doctor runs inside finalize!) ----

  def test_a_drawing_program_finalizes_into_a_valid_rom
    rom = lower(program(display(:bitmap), clear_screen(:blue), halt))
    assert_instance_of RubyGBA::ROM, rom
    assert_operator rom.size, :>, 0xC0
  end

  # ---- it actually runs and draws (gemba; skips when absent) ----

  def test_clear_screen_fills_the_whole_screen
    rom = lower(program(display(:bitmap), clear_screen(:blue), halt))
    v = assert_gemba_loads_rom(rom, frames: 5)
    assert v.blue?(0, 0)
    assert v.blue?(239, 159)
  end

  def test_a_constant_pixel_lands_at_its_coordinates
    rom = lower(program(display(:bitmap), clear_screen(:black), pixel(10, 20, :red), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 20)
    assert v.black?(11, 20)
  end

  def test_fill_rect_paints_its_block
    rom = lower(program(display(:bitmap), clear_screen(:black), fill_rect(5, 5, 4, 3, :green), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.green?(5, 5)
    assert v.green?(8, 7)  # bottom-right corner (5+4-1, 5+3-1)
    assert v.black?(9, 5)  # just outside
  end

  def test_arithmetic_drives_a_computed_pixel_coordinate
    # x = 5 + 5 = 10, then plot at (x, 0): proves variables + arithmetic + a
    # runtime-computed VRAM address all lower correctly.
    rom = lower(program(
      display(:bitmap),
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
      display(:bitmap),
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
      display(:bitmap),
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
      display(:bitmap),
      loop_(wait_vblank, if_(pressed(:start), pixel(10, 10, :red))),
    ))
    assert_instance_of RubyGBA::ROM, rom
  end

  def test_pressed_does_not_fire_without_input
    rom = lower(program(
      display(:bitmap),
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
      display(:bitmap),
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

  # ---- abs / negate_abs (observed by driving a pixel coordinate) ----

  def test_abs_makes_a_negative_value_positive
    # v = -5, abs -> 5; plotting at (v, 0) lands at x=5. If abs left it negative
    # the coordinate would clip off-screen and nothing would appear at (5, 0).
    rom = lower(program(
      display(:bitmap), clear_screen(:black),
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
      display(:bitmap), clear_screen(:black),
      set(:v, 6), negate(:v), negate_abs(:v), add(:v, 20),
      pixel(:v, 0, :red), halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(14, 0)
    assert v.black?(26, 0)
  end

  # ---- extended draws: dma_fill_rect / draw_rect_at / draw_text ----

  def test_dma_fill_rect_paints_its_block
    rom = lower(program(display(:bitmap), clear_screen(:black),
                        dma_fill_rect(4, 6, 4, 2, :red), halt))
    v = assert_gemba_loads_rom(rom)
    assert v.red?(4, 6)
    assert v.red?(7, 7)   # bottom-right (4+4-1, 6+2-1)
    assert v.black?(8, 6) # just outside
  end

  def test_draw_rect_at_paints_at_a_runtime_position
    # The rectangle's position comes from variables computed at run time.
    rom = lower(program(
      display(:bitmap), clear_screen(:black),
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
      display(:bitmap), clear_screen(:black),
      set(:x, 10), add(:x, 10),
      draw_rect_at(:x, 50, 4, 4, :white),
      halt,
    ))
    v = assert_gemba_loads_rom(rom)
    assert v.white?(20, 50)
    assert v.black?(19, 50)
  end

  def test_draw_text_renders_glyphs
    rom = lower(program(display(:bitmap), clear_screen(:black),
                        draw_text("HI", 40, 30, :white), halt))
    v = assert_gemba_loads_rom(rom)
    # 'H' row 0 = 0x11: leftmost and rightmost columns lit, middle not.
    assert v.white?(40, 30)      # left post of 'H'
    assert v.white?(44, 30)      # right post of 'H'
    assert v.black?(42, 30)      # gap between the posts
  end

  def test_odd_width_dma_fill_is_a_friendly_error
    err = assert_raises(GBA::LoweringError) do
      lower(program(display(:bitmap), dma_fill_rect(0, 0, 3, 2, :red), halt))
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

  def test_enabling_sound_without_a_beep_stays_silent
    rom = lower(program(enable_sound, halt))
    v = assert_gemba_loads_rom(rom, frames: 8)
    assert v.silent?, "no beep means no sound"
  end

  def test_play_song_drives_the_music_channel
    rom = lower(program(
      display(:bitmap),
      enable_sound,
      song(:tune, events: [[1, 262], [2, 330], [3, 392]], total_frames: 8),
      loop_(wait_vblank, play_song(:tune)),
    ))
    v = assert_gemba_loads_rom(rom, frames: 10)
    assert v.sound?, "play_song should trigger notes on the music channel"
  end

  def test_play_song_for_an_undefined_song_is_a_lowering_error
    assert_raises(GBA::LoweringError) do
      lower(program(enable_sound, play_song(:ghost), halt))
    end
  end

  def test_case_var_dispatches_to_the_active_scene
    # state == 1 -> the :playing scene draws blue; :title (state 0) draws red.
    rom = lower(program(
      display(:bitmap),
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
