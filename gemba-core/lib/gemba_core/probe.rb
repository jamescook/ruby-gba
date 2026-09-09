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

    # The whole current frame as the emulator's raw bytes — {BYTES_PER_PIXEL} per pixel,
    # rows top to bottom. {#pixel} reads one out of this; a caller comparing the WHOLE
    # picture against something wants it in one piece rather than 38,400 calls.
    #
    # WHAT THIS IS A PICTURE OF, which matters for the one job it was added for: the
    # display draws each scanline as it reaches it, out of video memory as it stands at
    # that moment. So this is what the screen really showed, mid-frame writes and all —
    # not a settled picture assembled at the end. A caller comparing it against video
    # memory afterwards is asking whether the game finished each row before the display
    # got there, which is the definition of a tear.
    #
    # @return [String] raw pixel bytes; raises until at least one {#step} has run
    def frame_buffer
      pixels!
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

    # WHERE THE CPU SPENT ITS FRAMES, as raw counts against raw addresses.
    #
    # The cycle measurements above say how much a frame costs. This says which
    # code it was spent in, which is the question somebody with a slow game
    # actually has. Every instruction the run executes is written down, so the
    # counts are exact rather than a statistical sample — an emulator can look
    # at each one, where a profiler on real hardware has to interrupt it now and
    # then and guess the rest.
    #
    # This stays a probe. It hands back ADDRESSES, because turning one into the
    # name of a routine needs the build that made the ROM, and that is not here.
    #
    # +halted+ is time with no code in it at all: the game has finished its work
    # and is asleep until the screen comes round. It is kept apart from the
    # counts on purpose — the address the CPU happens to hold while it sleeps is
    # wherever it went to sleep, and blaming that line for the wait would be the
    # most misleading thing this could report. It is in CYCLES, not instructions,
    # because a sleep is time rather than code; {#idle_share} puts it against the
    # frame it slept through.
    Profile = Data.define(:frames, :samples, :halted, :elsewhere, :finished, :pc,
                          :cycles_per_frame) do
      # The addresses that came up most, dearest first.
      #
      # @return [Array<Array(Integer, Integer)>] pairs of [address, times seen]
      def hottest(count = 10) = pc.sort_by { |_, seen| -seen }.first(count)

      # What share of the run's instructions ran at these addresses, 0.0 to 1.0.
      # Takes anything that answers +include?+ — a Range covering a routine, or
      # a Set of addresses.
      def share_of(addresses)
        return 0.0 if samples.zero?

        pc.sum { |addr, seen| addresses.include?(addr) ? seen : 0 } / samples.to_f
      end

      # Instructions per frame, which is what a frame's work amounts to once the
      # sleeping is taken out.
      def samples_per_frame = frames.zero? ? 0.0 : samples / frames.to_f

      # How much of the run the console spent asleep, 0.0 to 1.0. This is the
      # headroom: a game idling four fifths of every frame has room to do four
      # times the work, and one near 0.0 has none and is about to miss a frame.
      def idle_share
        total = frames * cycles_per_frame
        return 0.0 if total.zero?

        [halted / total.to_f, 1.0].min
      end

      # WHAT THE CONSOLE IS ACTUALLY PRODUCING, in frames a second.
      #
      # The screen refreshes sixty times a second whatever the game does, so
      # that is not the question. The question is how often the game gets a NEW
      # picture ready in time, and a game that misses shows the same one twice —
      # which is what a player sees as choppiness. So this counts the frames the
      # game finished its work in: all of them is sixty, one in three is twenty.
      #
      # It is measured from the console, so it is the rate of the cartridge in
      # front of you rather than of anything drawing it. It needs no counter put
      # into the game and no rebuild.
      #
      # IT IS COARSE BY NATURE and {#idle_share} is the finer reading. A game
      # loop waits for the screen, so a pass takes a whole number of frames and
      # this can only land on 60, 30, 20, 15. A game using a quarter of its frame
      # and one using all but a scanline of it BOTH read 60; what is left over
      # tells them apart.
      def frames_per_second
        return 0.0 if frames.zero?

        (60.0 * finished / frames).round(1)
      end

      # True when the game did not finish its work in every frame of the run.
      def dropping_frames? = finished < frames
    end

    # Run +frames+ frames and report where the CPU was — see {Profile}.
    #
    # Pass +settle:+ to run that many frames first so the ROM is past its boot
    # and into its game loop, and +keys:+ to hold buttons for the settling AND
    # the profiled frames. Both matter more here than anywhere else: a profile
    # of a title screen, or of a game standing still, is a profile of the wrong
    # thing.
    #
    # @return [Profile]
    def profile(frames: 1, settle: 0, keys: nil)
      ensure_open!
      step(settle, keys: keys) if settle.positive?
      raw = @core.profile(frames, keys_mask(keys))
      @frames_run += frames
      @prev_pixels = @pixels
      @pixels = @core.video_buffer
      Profile.new(frames: raw[:frames], samples: raw[:samples], halted: raw[:halted],
                  elsewhere: raw[:elsewhere], finished: raw[:finished], pc: raw[:pc],
                  cycles_per_frame: frame_cycles)
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
