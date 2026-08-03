# frozen_string_literal: true

require_relative "test_helper"

# Tests for the cost/timing probe — measuring the CPU cycles a ROM actually
# burns per frame, the signal used to calibrate ruby-gba's cost model against
# real emitted code. These assert the behavioral contract (positive, monotonic
# with workload, bounded by a frame) rather than exact cycle counts, which are
# emulator-specific.
class TestGembaCoreTiming < Minitest::Test
  include GembaCoreTestSupport

  # A game loop that only waits for vblank each frame — the CPU is asleep almost
  # the whole frame, so it burns almost nothing.
  def idle_rom
    build_rom("IDLE", code: "TIDL") do
      screen :bitmap
      clear_screen :black
      game_loop { wait_vblank }
    end
  end

  # A loop that does real (but sub-frame) work each frame: 500 add iterations.
  def worker_rom
    build_rom("WORK", code: "TWRK") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      game_loop do
        wait_vblank
        repeat(500) { add :x, 1 }
      end
    end
  end

  # A loop that does one wide DMA fill each frame. The CPU issues the fill in a few
  # register writes (cheap, counted as busy) then is STALLED while the DMA engine copies
  # the pixels — that stall is real frame time the busy count alone cannot see.
  def dma_rom
    build_rom("DMAF", code: "TDMA") do
      screen :bitmap
      clear_screen :black
      b = self
      game_loop { wait_vblank; b.dma_fill_rect 0, 0, 200, 100, :red }
    end
  end

  def test_frame_and_scanline_constants
    with_probe(idle_rom) do |probe|
      probe.step(1)
      assert_equal 280_896, probe.frame_cycles, "a GBA frame is 280896 cycles"
      assert_in_delta 1232.0, probe.cycles_per_scanline, 1.0, "~1232 cycles per scanline"
    end
  end

  def test_global_cycles_advances_by_a_frame_each_run
    with_probe(idle_rom) do |probe|
      probe.step(2)
      before = probe.global_cycles
      probe.step(1)
      assert_equal probe.frame_cycles, probe.global_cycles - before,
                   "one frame advances global time by exactly frame_cycles"
    end
  end

  def test_idle_loop_is_nearly_free
    with_probe(idle_rom) do |probe|
      busy = probe.busy_cycles(settle: 8)
      assert_operator busy, :>, 0, "even an idle loop does a little work per frame"
      assert_operator busy / probe.cycles_per_scanline, :<, 10.0,
                      "a wait-for-vblank loop costs well under 10 scanlines"
    end
  end

  def test_busy_cycles_grows_with_workload_and_stays_within_a_frame
    idle = with_probe(idle_rom) { |p| p.busy_cycles(settle: 8) }
    work = with_probe(worker_rom) { |p| p.busy_cycles(settle: 8) }

    assert_operator work, :>, idle * 10, "500 adds/frame cost far more than an idle loop"
    with_probe(worker_rom) do |probe|
      probe.step(8)
      assert_operator probe.busy_cycles, :<, probe.frame_cycles,
                      "a sub-frame workload fits inside one frame"
    end
  end

  def test_busy_scanlines_is_in_frame_range
    with_probe(worker_rom) do |probe|
      scanlines = probe.busy_scanlines(settle: 8)
      assert_kind_of Float, scanlines
      assert_operator scanlines, :>, 0.0
      assert_operator scanlines, :<, 228.0, "busy work is a fraction of the 228-scanline frame"
    end
  end

  def test_idle_rom_halts_waiting_for_vblank
    with_probe(idle_rom) do |probe|
      probe.step(6)
      assert_equal true, probe.cpu_halted?, "an idle game loop is halted at the frame boundary"
    end
  end

  # frame_cost splits a frame into the CPU-executing part (busy) and the wall-clock
  # work (active = busy plus the DMA-stall). A DMA fill's transfer is invisible to the
  # busy count — the CPU is stalled, not executing — but it is real frame time, so the
  # active reading is far higher than busy for a DMA-heavy frame.
  def test_frame_cost_sees_the_dma_stall_the_busy_count_misses
    with_probe(dma_rom) do |probe|
      cost = probe.frame_cost(settle: 8)
      assert_operator cost.busy_scanlines, :<, 10.0,
                      "the CPU only issues the fill — a handful of register writes"
      assert_operator cost.active_scanlines, :>, cost.busy_scanlines + 5.0,
                      "the DMA-stall makes the frame's wall-clock work far exceed the CPU part"
      assert_in_delta cost.active_scanlines - cost.busy_scanlines, cost.dma_scanlines, 0.001,
                      "dma is exactly the active-minus-busy stall"
    end
  end

  # A loop that only computes has no DMA, so its wall-clock work is just its CPU work —
  # active tracks busy and the DMA-stall is nil.
  def test_frame_cost_has_no_dma_stall_for_a_cpu_only_loop
    with_probe(worker_rom) do |probe|
      cost = probe.frame_cost(settle: 8)
      assert_operator cost.active_scanlines, :>, 0.0, "the loop does real per-frame work"
      assert_in_delta cost.busy_scanlines, cost.active_scanlines, 2.0,
                      "no DMA, so wall-clock work is about the CPU work"
      assert_operator cost.dma_scanlines, :<, 2.0, "no DMA means no stall"
    end
  end
end
