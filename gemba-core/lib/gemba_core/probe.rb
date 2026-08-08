# frozen_string_literal: true

module GembaCore
  # A headless, dev-only probe over a GBA ROM.
  #
  # Probe wraps a {Core} and hands back plain Ruby data — pixels as [r, g, b],
  # memory as integers, audio as an energy number, and a whole-frame +snapshot+
  # Hash — so a test or a REPL can see exactly what a frame contains with no UI
  # in the way. It exists to answer "what is this ROM actually doing, frame by
  # frame?" without booting the full gemba emulator/SDL stack.
  #
  # @example Step a red-screen ROM and read the middle pixel
  #   probe = GembaCore::Probe.new("game.gba")
  #   probe.step(6)                 # advance 6 frames
  #   probe.pixel(120, 80)          # => [255, 0, 0]
  #   probe.snapshot                # => {frame: 6, width: 240, ...}
  #   probe.close
  #
  # @example Hold a button while stepping
  #   probe.step(10, keys: :right)  # right held for 10 frames
  #   probe.step(2, keys: %i[a b])  # A+B held for 2 frames
  class Probe
    # Native pixels are 4 bytes each: byte 0 = red, 1 = green, 2 = blue,
    # 3 = unused padding (mGBA's XBGR8 color_t, little-endian).
    BYTES_PER_PIXEL = 4

    attr_reader :width, :height, :frames_run

    # @param rom_path [String] path to a .gba (or .gb/.gbc) ROM file
    def initialize(rom_path)
      @core = Core.new(rom_path)
      @width = @core.width
      @height = @core.height
      @frames_run = 0
      @pixels = nil       # raw video buffer for the current frame
      @prev_pixels = nil  # raw video buffer for the frame before it
      @last_audio = +"".b # audio drained during the most recent step
    end

    # Advance the emulation by +n+ frames, holding +keys+ for each.
    #
    # @param n [Integer] number of frames to run
    # @param keys [Symbol, Array<Symbol>, Integer, nil] buttons to hold —
    #   a name (+:right+), a list of names (+%i[a b]+), a raw +KEY_*+ bitmask,
    #   or nil / [] for no input.
    # @return [self]
    def step(n = 1, keys: nil)
      ensure_open!
      mask = keys_mask(keys)
      @last_audio = +"".b
      n.times do
        @core.set_keys(mask)
        @core.run_frame
        @last_audio << @core.audio_buffer
        @frames_run += 1
      end
      @prev_pixels = @pixels
      @pixels = @core.video_buffer
      self
    end

    # The colour at (x, y) on the current frame as [red, green, blue],
    # each 0..255. Raises until at least one {#step} has run.
    #
    # @return [Array(Integer, Integer, Integer)]
    def pixel(x, y)
      px = pixels!
      validate_coords!(x, y)
      off = ((y * @width) + x) * BYTES_PER_PIXEL
      [px.getbyte(off), px.getbyte(off + 1), px.getbyte(off + 2)]
    end

    # True when (x, y) is black (all channels zero) on the current frame.
    def black?(x, y)
      pixel(x, y) == [0, 0, 0]
    end

    # Read one byte (0..255) from the GBA address bus — any mapped region
    # (IWRAM 0x03000000+, EWRAM 0x02000000+, VRAM, I/O registers).
    def read8(address)
      ensure_open!
      @core.bus_read8(address)
    end

    # Read a little-endian halfword (0..65535) from the address bus.
    def read16(address)
      ensure_open!
      @core.bus_read16(address)
    end

    # Read a little-endian word (0..2**32-1) from the address bus.
    def read32(address)
      ensure_open!
      @core.bus_read32(address)
    end

    # A rough loudness of the audio drained during the last {#step}: the mean
    # square of the 16-bit samples (0 when silent). Use it to answer "did the
    # speaker do anything this step?" without decoding the waveform.
    #
    # @return [Float]
    def audio_energy
      return 0.0 if @last_audio.empty?

      samples = @last_audio.unpack("s<*")
      return 0.0 if samples.empty?

      sum = samples.sum { |s| s * s }
      sum.to_f / samples.length
    end

    # True when the last step produced effectively no sound.
    #
    # @param threshold [Numeric] energy at or below which counts as silent
    def silent?(threshold = 1.0)
      audio_energy <= threshold
    end

    # --- cost / timing (for calibrating the cost model) --------------------

    # A GBA video frame is 228 scanlines of CPU time. The cost model counts in
    # scanlines, so a measured cycle count divides by this to land in its unit.
    SCANLINES_PER_FRAME = 228

    # Cumulative emulated CPU cycles since reset.
    def global_cycles
      ensure_open!
      @core.global_cycles
    end

    # Cycles in one video frame (constant, ~280896 on GBA).
    def frame_cycles
      ensure_open!
      @core.frame_cycles
    end

    # Emulated CPU cycles per scanline (~1232 on GBA).
    def cycles_per_scanline
      frame_cycles.to_f / SCANLINES_PER_FRAME
    end

    # Whether the CPU is currently halted (asleep until the next interrupt).
    def cpu_halted?
      ensure_open!
      @core.cpu_halted?
    end

    # Measure the CPU cycles this ROM actually burns in one frame — the cycles
    # it spends executing, not halted waiting for vblank. This is the real
    # per-frame cost of the game loop, the number to calibrate op weights
    # against. Advancing the measurement steps one frame of emulated time.
    #
    # Pass +settle:+ to run that many frames first so the ROM is in steady state
    # (past boot) before the measured frame, and +keys:+ to hold buttons for the
    # settling AND the measured frame — a game costs what the player makes it
    # cost, so a reading with nothing held is a reading of a game standing still.
    #
    # Meaningful for a workload that FITS in a frame (the regime you calibrate
    # in): there it's stable and repeatable. A ROM whose per-frame work can't
    # finish in one frame has no single per-frame cost — the number caps out
    # near a full frame and wobbles, which is the honest answer.
    #
    # @return [Integer] busy cycles for the measured frame
    def busy_cycles(settle: 0, keys: nil)
      ensure_open!
      step(settle, keys: keys) if settle.positive?
      @core.set_keys(keys_mask(keys))
      cycles = @core.measure_frame_busy_cycles
      @frames_run += 1
      @prev_pixels = @pixels
      @pixels = @core.video_buffer
      cycles
    end

    # {#busy_cycles} expressed in the cost model's unit — scanlines.
    #
    # @return [Float]
    def busy_scanlines(settle: 0, keys: nil)
      busy_cycles(settle: settle, keys: keys) / cycles_per_scanline
    end

    # One frame's cost split into the CPU-executing part and the wall-clock
    # work. The GBA stalls the CPU while a DMA engine copies, so a DMA-heavy
    # frame burns real frame budget the busy count alone cannot see. +active+
    # is everything but the end-of-frame halt (executing plus DMA-stall);
    # +dma+ is the difference — the stall time.
    #
    # Neither number is the whole cost on its own. +active+ is measured as the
    # frame minus the time the CPU spent halted, so a ROM the hardware wakes
    # over and over — one taking an interrupt on every scanline, say — has some
    # of its waking time counted into a halt and reads BELOW its own +busy+.
    # When a single figure is wanted for "what did this frame cost", take the
    # larger of the two: each is blind to something the other sees, and neither
    # can overstate a frame.
    FrameCost = Data.define(:busy_cycles, :active_cycles, :cycles_per_scanline) do
      def busy_scanlines = busy_cycles / cycles_per_scanline
      def active_scanlines = active_cycles / cycles_per_scanline

      # The DMA-stall cycles: active minus busy. Floored at 0 — a tiny negative
      # can appear when a few executing cycles have not yet folded into global
      # time at the frame boundary.
      def dma_cycles = [active_cycles - busy_cycles, 0].max
      def dma_scanlines = dma_cycles / cycles_per_scanline
    end

    # Measure one frame and return its {FrameCost} — busy and active (wall-clock)
    # cycles from the same pass, so their DMA-stall difference is exact. Pass
    # +settle:+ to reach steady state first and +keys:+ to hold buttons, like
    # {#busy_cycles}.
    #
    # @return [FrameCost]
    def frame_cost(settle: 0, keys: nil)
      ensure_open!
      step(settle, keys: keys) if settle.positive?
      @core.set_keys(keys_mask(keys))
      busy, active = @core.measure_frame_work
      @frames_run += 1
      @prev_pixels = @pixels
      @pixels = @core.video_buffer
      FrameCost.new(busy_cycles: busy, active_cycles: active, cycles_per_scanline: cycles_per_scanline)
    end

    # Number of pixels lit (non-black) on the current frame — a cheap
    # "is anything on screen?" measure.
    #
    # @return [Integer]
    def lit_pixels
      GembaCore.count_changed_pixels(pixels!)
    end

    # Number of pixels that changed between the previous frame and the current
    # one. 0 before two frames have run (nothing to compare against yet).
    #
    # @return [Integer]
    def changed_pixels
      return 0 unless @pixels && @prev_pixels

      GembaCore.count_changed_pixels(GembaCore.xor_delta(@pixels, @prev_pixels))
    end

    # A plain-Hash summary of where the ROM is right now — the headline numbers
    # a dev glances at each step. Handy to +pp+ in a loop or diff across frames.
    #
    # @return [Hash]
    def snapshot
      {
        frame: @frames_run,
        width: @width,
        height: @height,
        title: title,
        lit_pixels: lit_pixels,
        changed_pixels: changed_pixels,
        audio_energy: audio_energy
      }
    end

    # The ROM's internal header title (up to 12 chars for GBA).
    def title
      ensure_open!
      @core.title
    end

    # Convert a key spec to the raw +set_keys+ bitmask. Accepts a Symbol name,
    # an Array of names, an Integer mask (passed through), or nil ([] → 0).
    #
    # @return [Integer]
    def keys_mask(keys)
      case keys
      when nil then 0
      when Integer then keys
      when Symbol then bit_for(keys)
      when Array then keys.sum { |k| k.is_a?(Integer) ? k : bit_for(k) }
      else
        raise ArgumentError, "keys must be a Symbol, Array, Integer or nil, got #{keys.inspect}"
      end
    end

    # Shut down the underlying core and free its buffers. Idempotent.
    def close
      @core.destroy unless @core.destroyed?
      nil
    end

    # Whether the underlying core has been shut down.
    def closed?
      @core.destroyed?
    end

    private

    def bit_for(name)
      GBA_BTN_BITS.fetch(name) do
        raise ArgumentError, "unknown button #{name.inspect} — known: #{GBA_BTN_BITS.keys.join(', ')}"
      end
    end

    # The current frame's raw pixels, or a friendly error if nothing's run yet.
    def pixels!
      @pixels || raise(RuntimeError, "no frame yet — call #step before reading pixels")
    end

    def ensure_open!
      raise RuntimeError, "probe has been closed" if @core.destroyed?
    end

    def validate_coords!(x, y)
      return if x.between?(0, @width - 1) && y.between?(0, @height - 1)

      raise ArgumentError, "(#{x}, #{y}) is off-screen (#{@width}x#{@height})"
    end
  end
end
