# frozen_string_literal: true

require "test_helper"

# The reference backend's simulated hardware: run hand-built IR programs that draw and
# read input, then assert what landed on the fake screen and which branch a
# supplied button state took. Still no emulator and no ROM — the point is that a
# game's *visible* behavior is assertable in-process.
class TestIRBackendReferenceHardware < Minitest::Test
  include RubyGBA::IR::Build

  def run_ir(node, **opts)
    Reference.new.run(node, **opts)
  end

  # ---- drawing into the framebuffer ----

  def test_clear_screen_paints_the_whole_screen
    i = run_ir(program(screen(:bitmap), clear_screen(:blue)))
    assert_equal Color.resolve(:blue), i.screen.pixel(0, 0)
    assert_equal Color.resolve(:blue), i.screen.pixel(239, 159)
  end

  # Double buffering changes only WHEN a frame becomes visible on hardware, never
  # which pixels land — and this oracle reads the settled end-of-frame image, so a
  # buffered program draws exactly the same screen. The flag is recorded, though.
  def test_double_buffering_records_the_flag_but_draws_the_same_pixels
    i = run_ir(program(screen(:bitmap, buffered: true), clear_screen(:blue)))
    assert i.buffered
    assert_equal Color.resolve(:blue), i.screen.pixel(120, 80)
  end

  def test_pixel_writes_a_resolved_color_at_coordinates
    i = run_ir(program(pixel(10, 20, :red)))
    assert_equal Color.resolve(:red), i.screen.pixel(10, 20)
    assert_equal 0, i.screen.pixel(11, 20) # neighbor untouched
  end

  def test_pixel_coordinates_can_come_from_variables
    i = run_ir(program(
      set(:px, 100),
      set(:py, 50),
      pixel(:px, :py, :green),
    ))
    assert_equal Color.resolve(:green), i.screen.pixel(100, 50)
  end

  def test_fill_rect_paints_a_block
    i = run_ir(program(fill_rect(5, 5, 3, 2, :yellow)))
    assert_equal Color.resolve(:yellow), i.screen.pixel(5, 5)
    assert_equal Color.resolve(:yellow), i.screen.pixel(7, 6) # bottom-right
    assert_equal 0, i.screen.pixel(8, 5)                      # just outside
  end

  def test_dma_fill_rect_paints_a_block
    # Same picture as fill_rect — the "DMA" is only how a console fills it fast.
    i = run_ir(program(dma_fill_rect(4, 6, 4, 2, :red)))
    assert_equal Color.resolve(:red), i.screen.pixel(4, 6)
    assert_equal Color.resolve(:red), i.screen.pixel(7, 7) # bottom-right (4+4-1, 6+2-1)
    assert_equal 0, i.screen.pixel(8, 6)                    # just outside
  end

  def test_draw_rect_at_positions_the_block_from_variables
    # The moving-object draw: its position comes from variables at run time.
    i = run_ir(program(
      set(:x, 30),
      set(:y, 40),
      draw_rect_at(:x, :y, 4, 4, :green),
    ))
    assert_equal Color.resolve(:green), i.screen.pixel(30, 40)
    assert_equal Color.resolve(:green), i.screen.pixel(33, 43) # bottom-right corner
    assert_equal 0, i.screen.pixel(34, 40)                     # just outside
  end

  def test_draw_text_renders_glyph_pixels
    # 'I' in the 5x7 font has a set pixel at its top-left corner (row 0 = 0x0E,
    # so columns 1..3 are lit) — assert a lit and an unlit cell of the glyph.
    i = run_ir(program(draw_text("I", 10, 20, :white)))
    assert_equal Color.resolve(:white), i.screen.pixel(11, 20) # a lit pixel of 'I'
    assert_equal 0, i.screen.pixel(10, 20)                      # an unlit corner
  end

  def test_draw_text_skips_unsupported_characters
    # The font has no '@'; drawing it must not raise, just render nothing.
    i = run_ir(program(draw_text("@", 0, 0, :white)))
    assert_equal 0, i.screen.pixel(0, 0)
  end

  def test_off_screen_pixel_is_clipped_without_error
    # The safe-by-default promise: a stray coordinate can't crash a program.
    i = run_ir(program(pixel(999, 999, :red)))
    assert_equal 0, i.screen.pixel(0, 0)
  end

  def test_screen_mode_is_recorded
    i = run_ir(program(screen(:bitmap)))
    assert_equal :bitmap, i.screen_mode
  end

  # ---- reading input ----

  def test_held_button_takes_the_branch
    i = Reference.new.hold(:a).run(program(
      if_(held(:a), set(:jumped, 1)),
      if_(held(:b), set(:shot, 1)),
    ))
    assert_equal 1, i[:jumped]
    assert_equal 0, i[:shot]
  end

  def test_unheld_button_skips_the_branch
    i = Reference.new.run(program(if_(held(:up), set(:moved, 1))))
    assert_equal 0, i[:moved]
  end

  def test_pressed_is_an_edge_only_the_first_frame_a_button_is_down
    # Button :a is held on every frame, but "pressed" should fire once — the
    # frame the button first goes down, not while it stays down.
    i = Reference.new.input_each_frame { |_frame| [:a] }.run(program(
      set(:count, 0),
      set(:presses, 0),
      loop_(
        wait_vblank,
        if_(pressed(:a), add(:presses, 1)),
        add(:count, 1),
        if_(binop(:>=, var_ref(:count), int(3)), halt),
      ),
    ))
    assert_equal 3, i[:count]
    assert_equal 1, i[:presses]
  end

  def test_unknown_button_is_a_friendly_error
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(program(if_(held(:triangle), set(:x, 1))))
    end
    assert_match(/triangle/, err.message)
  end

  # ---- audio (an observable record of what would play) ----

  def test_sound_ops_are_recorded_in_the_audio_log
    i = run_ir(program(enable_sound, beep(:high), stop_music))
    assert_equal [:enabled], i.audio[0]
    assert_equal :beep, i.audio[1][0]
    assert_equal 880, i.audio[1][1][:frequency] # :high resolves to 880 Hz
    assert_equal [:stop_music], i.audio[2]
  end

  def test_a_noise_hit_is_recorded_with_its_resolved_values
    i = run_ir(program(enable_sound, noise(:explosion)))
    assert_equal :noise, i.audio[1][0]
    assert_equal({ pitch: :low, decay: :slow, volume: 15, metallic: false }, i.audio[1][1])
  end

  def test_a_wave_tone_and_its_stop_are_recorded
    i = run_ir(program(enable_sound, wave(shape: :triangle, frequency: 262, volume: :full), stop_wave))
    assert_equal [:wave, { shape: :triangle, frequency: 262, volume: :full }], i.audio[1]
    assert_equal [:stop_wave], i.audio[2]
  end

  def test_beep_resolves_a_defined_sound_by_name
    i = run_ir(program(
      enable_sound,
      define_sound(:paddle, frequency: 500, duty: :quarter, decay: :fast, volume: 12),
      beep(:paddle),
    ))
    effect = i.audio.find { |e| e[0] == :beep }[1]
    assert_equal 500, effect[:frequency]
    assert_equal :quarter, effect[:duty]
  end

  def test_a_beep_override_wins_over_the_preset
    i = run_ir(program(enable_sound, beep(:high, volume: 3)))
    assert_equal 3, i.audio.find { |e| e[0] == :beep }[1][:volume]
  end

  def test_play_song_triggers_notes_frame_by_frame_and_loops
    i = run_ir(program(
      enable_sound,
      song(:tune, events: [[0, 262], [2, 330]], total_frames: 4),
      set(:n, 0),
      loop_(
        wait_vblank,
        play_song(:tune),
        add(:n, 1),
        if_(binop(:>=, var_ref(:n), int(6)), halt),
      ),
    ))
    notes = i.audio.select { |e| e[0] == :note }
    # The counter runs 0,1,2,3,0,1: frame 0 fires 262 (the downbeat), frame 2 fires
    # 330, then it wraps at length 4 and frame 0 fires 262 again — the loop.
    assert_equal [[:note, :tune, 262], [:note, :tune, 330], [:note, :tune, 262]], notes
  end

  # A layered song's parts play against one shared frame counter, so notes on the
  # same frame in different parts sound together.
  def test_play_song_plays_layered_parts_together
    i = run_ir(program(
      enable_sound,
      song(:duet, total_frames: 4, voices: [
        { events: [[0, 523], [2, 587]], duty: :half, volume: 12 }, # melody: C5 then D5
        { events: [[0, 131]], duty: :half, volume: 8 },            # bass: C3, held
      ]),
      set(:n, 0),
      loop_(
        wait_vblank,
        play_song(:duet),
        add(:n, 1),
        if_(binop(:>=, var_ref(:n), int(3)), halt),
      ),
    ))
    notes = i.audio.select { |e| e[0] == :note }
    # Frame 0: melody C5 (523) and bass C3 (131) together; frame 2: melody D5 (587).
    assert_includes notes, [:note, :duet, 523]
    assert_includes notes, [:note, :duet, 131]
    assert_includes notes, [:note, :duet, 587]
  end

  # ---- observation log ----

  def test_log_records_vblank_ticks_and_halt
    i = run_ir(program(
      set(:x, 0),
      loop_(
        wait_vblank,
        add(:x, 1),
        if_(binop(:>=, var_ref(:x), int(2)), halt),
      ),
    ))
    assert_equal [[:vblank, 1], [:vblank, 2], [:halt]], i.log
  end
end
