# frozen_string_literal: true

require_relative "test_helper"

# Tests for GembaCore::Probe — the dev-facing wrapper that returns plain data
# (pixels as [r,g,b], memory as ints, audio as an energy number, a snapshot
# Hash). Each test builds a ruby-gba ROM whose output is known, so a wrong
# read shows up as a wrong number, not a skip.
class TestGembaCoreProbe < Minitest::Test
  include GembaCoreTestSupport

  def test_reads_a_known_pixel_colour
    with_probe(red_rom) do |probe|
      probe.step(6)
      assert_equal [255, 0, 0], probe.pixel(120, 80), "the middle of a red screen is red"
      assert_equal [255, 0, 0], probe.pixel(0, 0)
      refute probe.black?(120, 80)
    end
  end

  def test_reads_distinct_regions_of_a_two_colour_screen
    # Blue background with a green rectangle stamped at a fixed spot: the probe
    # should read blue outside it and green inside it.
    rom = build_rom("SPLIT", code: "TSPL") do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 60, 40, 40, :green
      game_loop { wait_vblank }
    end
    with_probe(rom) do |probe|
      probe.step(4)
      assert_equal [0, 255, 0], probe.pixel(120, 80), "inside the green rect"
      assert_equal [0, 0, 255], probe.pixel(10, 10), "outside it, on blue"
    end
  end

  def test_pixel_before_stepping_is_a_friendly_error
    with_probe(red_rom) do |probe|
      err = assert_raises(RuntimeError) { probe.pixel(0, 0) }
      assert_match(/step/, err.message)
    end
  end

  def test_off_screen_pixel_is_rejected
    with_probe(red_rom) do |probe|
      probe.step(1)
      assert_raises(ArgumentError) { probe.pixel(240, 0) }
      assert_raises(ArgumentError) { probe.pixel(0, 160) }
    end
  end

  def test_snapshot_reports_the_frame_state
    with_probe(red_rom) do |probe|
      probe.step(6)
      snap = probe.snapshot
      assert_equal 6, snap[:frame]
      assert_equal 240, snap[:width]
      assert_equal 160, snap[:height]
      assert_equal "RED", snap[:title]
      assert_equal 240 * 160, snap[:lit_pixels], "a full red screen lights every pixel"
      assert_equal 0.0, snap[:audio_energy]
    end
  end

  def test_frames_run_accumulates_across_steps
    with_probe(red_rom) do |probe|
      probe.step(3)
      probe.step(2)
      assert_equal 5, probe.frames_run
    end
  end

  def test_changed_pixels_is_zero_on_a_static_screen
    with_probe(red_rom) do |probe|
      probe.step(2)
      probe.step(1) # nothing moves
      assert_equal 0, probe.changed_pixels
    end
  end

  def test_held_input_is_plumbed_through_to_the_rom
    # A white rect whose x advances by 2 each frame while RIGHT is held. With no
    # input it stays near x=20; with RIGHT held for 10 frames it reaches ~x=40.
    mover = lambda do
      build_rom("MOVER", code: "TMOV") do
        screen :bitmap
        var :x, 20
        game_loop do
          wait_vblank
          held(:right).then { add :x, 2 }
          clear_screen :black
          draw_rect_at :x, 78, 8, 8, :white
        end
      end
    end

    with_probe(mover.call) do |probe|
      probe.step(10) # no keys
      assert_equal [0, 0, 0], probe.pixel(45, 80), "rect stayed left, (45,80) is background"
    end

    with_probe(mover.call) do |probe|
      probe.step(10, keys: :right)
      assert_equal [255, 255, 255], probe.pixel(45, 80), "RIGHT moved the rect under (45,80)"
    end
  end

  def test_audio_energy_hears_a_sustained_tone
    rom = build_rom("TONE", code: "TTON") do
      screen :bitmap
      clear_screen :black
      enable_sound
      wave :square, :A4 # a steady tone that holds
      game_loop { wait_vblank }
    end
    with_probe(rom) do |probe|
      probe.step(8)
      assert_operator probe.audio_energy, :>, 0.0, "a sustained tone is not silent"
      refute probe.silent?
    end
  end

  def test_keys_mask_accepts_symbol_array_and_integer
    with_probe(red_rom) do |probe|
      assert_equal 0, probe.keys_mask(nil)
      assert_equal 0, probe.keys_mask([])
      assert_equal GembaCore::KEY_RIGHT, probe.keys_mask(:right)
      assert_equal GembaCore::KEY_A | GembaCore::KEY_B, probe.keys_mask(%i[a b])
      assert_equal GembaCore::KEY_START, probe.keys_mask(GembaCore::KEY_START)
    end
  end

  def test_unknown_button_is_a_friendly_error
    with_probe(red_rom) do |probe|
      err = assert_raises(ArgumentError) { probe.keys_mask(:jump) }
      assert_match(/unknown button/, err.message)
      assert_match(/jump/, err.message)
    end
  end

  def test_memory_reads_reach_the_bus
    with_probe(red_rom) do |probe|
      probe.step(4)
      assert_equal 0x403, probe.read16(0x04000000)
      assert_equal 0x403, probe.read32(0x04000000) & 0xFFFF
      assert_equal 0x03, probe.read8(0x04000000)
    end
  end

  def test_close_is_idempotent_and_observable
    probe = GembaCore.open(red_rom)
    probe.step(1)
    refute_predicate probe, :closed?
    probe.close
    assert_predicate probe, :closed?
    probe.close # no raise on second close
    assert_raises(RuntimeError) { probe.step(1) }
  end
end
