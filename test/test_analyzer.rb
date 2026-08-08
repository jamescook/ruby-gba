# frozen_string_literal: true

require "test_helper"

require "tmpdir"

# The Analyzer measures a built ROM's real per-frame CPU cost on the emulator — the
# measured counterpart to the static cost estimate. These run real ROMs through gemba
# and read the busy scanlines a frame burns.
class TestAnalyzer < Minitest::Test

  Analyzer = RubyGBA::Analyzer

  # Build a program, write it to a temp .gba, and measure it.
  def measure(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "ANLZ", code: "BANL", maker: "01")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.gba")
      rom.write(path)
      return RubyGBA::Analyzer.measure(path)
    end
  end

  def test_a_light_loop_measures_a_small_per_frame_cost
    result = measure do
      screen :bitmap
      game_loop { wait_vblank }
    end
    assert_operator result.scanlines, :>, 0, "the CPU does some work each frame"
    refute result.saturated?, "a near-empty loop is nowhere near the 228-scanline ceiling"
    assert_operator result.percent, :<, 100
  end

  # The framerate measurement counts game-loop iterations. A loop that just waits each
  # frame runs at the full 60, which is what the injected counter should report.
  def test_measure_fps_counts_game_loop_iterations
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    fps = Analyzer.measure_fps(b.program)
    assert_in_delta 60, fps, 6, "a loop that waits each frame runs at ~60fps"
  end

  # Scene discovery reads the case dispatch straight from the IR — the selector variable
  # and each scene's value — so the profiler can boot into any one. No emulator needed.
  def test_scenes_discovers_the_dispatch
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :blue }
      scene(:play) { clear_screen :red }
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions
    dispatch = Analyzer.scenes(b.program)
    assert_equal :state, dispatch[:selector]
    assert_equal({ title: 0, play: 1 }, dispatch[:scenes])
  end

  # Boot-into overrides the LAST boot set of the selector, so a game that sets its state
  # more than once at start still ends up in the chosen scene.
  def test_boot_into_overrides_the_last_selector_set
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      set :state, 3 # a second boot-time set — must not undo the override
      scene(:a) { clear_screen :red }
      scene(:b) { clear_screen :blue }
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    program = Analyzer.boot_into(b.program, :state, 1)
    last = program.children.select { |n| n.kind == :set && n[:var] == :state }.last
    assert_equal 1, last[:value][:value], "the last boot set of the selector wins, at the target scene"
  end

  def test_boot_into_without_a_selector_init_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      scene(:a) { clear_screen :red }
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    err = assert_raises(ArgumentError) { Analyzer.boot_into(b.program, :state, 0) }
    assert_match(/never sets its scene variable/, err.message)
  end

  def test_scenes_is_nil_for_a_single_loop_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    assert_nil Analyzer.scenes(b.program)
  end

  # The probe has two clocks and each is blind to something. The wall-clock one counts the
  # stall while a DMA engine copies, which the CPU-executing count cannot see; but it is
  # measured by summing the CPU's sleeps, so a program the hardware wakes over and over
  # comes out BELOW the cycles it demonstrably executed. A background bending row by row is
  # woken 228 times a frame, which is that case — so a reading must never be less than the
  # CPU it can be shown to burn.
  def test_a_reading_is_never_less_than_the_cpu_the_frame_burns
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :ts, "#" => :t
      bg = background :bg, tiles: :ts, map: Array.new(20, "#" * 30)
      bg.scroll_each_row { |row| row % 8 }
      game_loop { }
    end
    b.emit_pending_functions
    program = b.program

    rom = ROM.assemble(GBA.new.lower(program), title: "ANLZ", code: "BANL", maker: "01")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bend.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(8)
      busy = 10.times.map { probe.frame_cost.busy_scanlines }.max
      probe.close

      reading = RubyGBA::Analyzer.measure(path)
      assert_operator busy, :>, 20, "bending really does cost this frame a lot of CPU"
      assert_operator reading.scanlines, :>=, busy,
                      "the reading must not come in under the CPU the frame demonstrably executed"
    end
  end

  # The Result's read of its own number: near the frame ceiling is "saturated" (the
  # measurement can't count past a frame's worth of work), below it is a plain percent.
  def test_result_reads_saturation_and_percent
    refute Analyzer::Result.new(scanlines: 50.0, fps: nil).saturated?
    assert Analyzer::Result.new(scanlines: 220.0, fps: 20.0).saturated?
    assert_equal 50, Analyzer::Result.new(scanlines: 114.0, fps: nil).percent
  end
end
