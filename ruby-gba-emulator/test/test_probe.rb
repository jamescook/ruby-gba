# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Tests for RubyGBAEmulator::Probe — the dev-facing wrapper that returns plain data
# (pixels as [r,g,b], memory as ints, audio as an energy number, a snapshot
# Hash). Each test builds a ruby-gba ROM whose output is known, so a wrong
# read shows up as a wrong number, not a skip.
class TestRubyGBAEmulatorProbe < Minitest::Test
  include RubyGBAEmulatorTestSupport

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
          held(:right).then { add! :x, 2 }
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
      assert_equal RubyGBAEmulator::KEY_RIGHT, probe.keys_mask(:right)
      assert_equal RubyGBAEmulator::KEY_A | RubyGBAEmulator::KEY_B, probe.keys_mask(%i[a b])
      assert_equal RubyGBAEmulator::KEY_START, probe.keys_mask(RubyGBAEmulator::KEY_START)
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

  # READING A WHOLE STRETCH AT ONCE. A game's state is an area of memory — a pool of
  # sixty guards, a list, a map — and asking for it a word at a time costs a call into the
  # emulator for every four bytes. A test that reads it every frame does that thousands of
  # times, and a suite of those does it millions.
  def test_a_stretch_of_memory_reads_the_same_as_asking_a_byte_at_a_time
    with_probe(red_rom) do |probe|
      probe.step(4)
      start = 0x0300_0000

      assert_equal (0...64).map { |i| probe.read8(start + i) },
                   probe.read_bytes(start, 64).bytes
    end
  end

  def test_a_stretch_read_as_words_is_the_same_as_asking_for_each
    rom = RubyGBA.build("BULK", validate: false) do
      screen :bitmap
      var :a, 11
      var :b, 22
      var :c, 33
      game_loop { wait_vblank }
    end
    with_probe(write_rom(rom, "bulk")) do |probe|
      probe.step(4)
      start = rom.var_addresses.fetch(:a)

      assert_equal [11, 22, 33], probe.read_words(start, 3)
      assert_equal [probe.read32(start), probe.read32(start + 4), probe.read32(start + 8)],
                   probe.read_words(start, 3)
    end
  end

  def test_reading_a_stretch_of_nothing_is_a_friendly_error
    with_probe(red_rom) do |probe|
      probe.step(1)

      assert_raises(ArgumentError) { probe.read_bytes(0x0300_0000, 0) }
      assert_raises(ArgumentError) { probe.read_bytes(0x0300_0000, -4) }
    end
  end

  def test_close_is_idempotent_and_observable
    probe = RubyGBAEmulator.open(red_rom)
    probe.step(1)
    refute_predicate probe, :closed?
    probe.close
    assert_predicate probe, :closed?
    probe.close # no raise on second close
    assert_raises(RuntimeError) { probe.step(1) }
  end

  # --- What the processor holds, at a chosen instruction ----------------------
  #
  # A program of three instructions written by hand, so where each one sits is known
  # without asking the build: the cartridge's code starts right after its header.

  CODE_START = 0x0800_0000 + RubyGBA::ROM::ENTRY_OFFSET

  def test_a_run_stops_at_an_address_and_reads_what_the_registers_hold_there
    rom = hand_written_rom(RubyGBA::ASM.load_immediate(4, 0x55) +
                           RubyGBA::ASM.load_immediate(5, 0x66) +
                           RubyGBA::ASM.loop_forever)
    with_probe(rom) do |probe|
      probe.run_until(CODE_START + 4)
      assert_equal CODE_START + 4, probe.registers[:pc]
      assert_equal 0x55, probe.registers[:r4], "the first instruction has run"
      refute_equal 0x66, probe.registers[:r5], "the second one has not"
    end
  end

  def test_a_run_that_never_reaches_the_address_says_so_rather_than_stopping_somewhere_else
    rom = hand_written_rom(RubyGBA::ASM.loop_forever)
    with_probe(rom) do |probe|
      err = assert_raises(RuntimeError) { probe.run_until(CODE_START + 0x100, limit: 1000) }
      assert_match(/0x080001C0/, err.message)
    end
  end

  # --- Where the cartridge's save memory goes ---------------------------------
  #
  # The emulator keeps a cartridge's battery-backed save chip as a .sav file, and left
  # to itself it writes one beside the ROM it opened, whether the game saves anything or
  # not. Looking at somebody's cartridge is not permission to write next to it, and a
  # second run that finds the first run's save is not the same run.

  def test_a_probe_writes_nothing_beside_the_rom_it_opened
    in_a_directory_of_its_own do |dir, rom|
      probe = RubyGBAEmulator.open(rom)
      probe.step(6)
      assert_equal ["saver.gba"], Dir.children(dir).sort, "the probe left a file beside the ROM"
      probe.close
      assert_equal ["saver.gba"], Dir.children(dir).sort, "closing the probe left a file behind"
    end
  end

  def test_a_probe_puts_the_save_where_it_is_told
    in_a_directory_of_its_own do |dir, rom|
      saves = File.join(dir, "saves")
      Dir.mkdir(saves)
      probe = RubyGBAEmulator.open(rom, save_dir: saves)
      probe.step(6)
      assert_equal ["saver.sav"], Dir.children(saves), "the save should be where it was told to go"
      probe.close
      assert_equal ["saver.sav"], Dir.children(saves), "a save the caller placed is the caller's"
    end
  end

  def test_the_temporary_save_directory_goes_away_with_the_probe
    in_a_directory_of_its_own do |_dir, rom|
      probe = RubyGBAEmulator.open(rom)
      probe.step(6)
      dir = probe.instance_variable_get(:@own_save_dir)
      assert Dir.exist?(dir), "the probe should have a save directory of its own while it runs"
      probe.close
      refute Dir.exist?(dir), "closing the probe should take its save directory away"
    end
  end

  private

  # A cartridge holding exactly these instructions and nothing the framework adds.
  def hand_written_rom(code)
    rom = RubyGBA::ROM.assemble(code, title: "BYHAND", code: "THND", maker: "01")
    tf = Tempfile.new(["byhand", ".gba"])
    tf.binmode
    rom.write(tf.path)
    tf.flush
    ROM_TEMPFILES << tf
    tf.path
  end

  # A scratch directory holding one ROM that really does save, so a .sav has a reason to
  # appear. Yields [directory, rom path]; the directory goes when the block ends.
  def in_a_directory_of_its_own
    Dir.mktmpdir("probe-save") do |dir|
      rom = RubyGBA.build("SAVER", code: "TSAV", maker: "01") do
        screen :bitmap
        high = save_var :high_score, 0
        s = var :s, 0
        game_loop do
          s.set! 7
          (s > high).then { high.set! s }
        end
      end
      path = File.join(dir, "saver.gba")
      rom.write(path)
      yield dir, path
    end
  end
end
