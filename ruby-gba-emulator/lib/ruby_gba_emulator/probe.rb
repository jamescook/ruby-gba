# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module RubyGBAEmulator
  # A headless, dev-only probe over a GBA ROM.
  #
  # Probe wraps a {Core} and hands back plain Ruby data — pixels as [r, g, b],
  # memory as integers, audio as an energy number, and a whole-frame +snapshot+
  # Hash — so a test or a REPL can see exactly what a frame contains with no UI
  # in the way. It exists to answer "what is this ROM actually doing, frame by
  # frame?" without booting a full emulator/SDL stack.
  #
  # @example Step a red-screen ROM and read the middle pixel
  #   probe = RubyGBAEmulator::Probe.new("game.gba")
  #   probe.step(6)                 # advance 6 frames
  #   probe.pixel(120, 80)          # => [255, 0, 0]
  #   probe.snapshot                # => {frame: 6, width: 240, ...}
  #   probe.close
  #
  # @example Hold a button while stepping
  #   probe.step(10, keys: :right)  # right held for 10 frames
  #   probe.step(2, keys: %i[a b])  # A+B held for 2 frames
  # ONE CHANGE TO A WATCHED ADDRESS: where it was, what the value had been, and what it
  # became. See {Probe#watch}.
  Change = Data.define(:address, :was, :now) do
    def to_s = format("0x%08X  %d -> %d", address, was, now)
  end

  # ONE WRITE THE GAME MADE TO THE DISPLAY, and where the picture had got to when it landed.
  #
  # +kind+ is +:register+ (where a layer sits, how it blends, what the screen is showing),
  # +:colour+ (one of the 512 colours the console draws from) or +:sprite+ (one halfword of
  # the table saying where the sprites are). +address+ is the hardware address for a register
  # and the offset into that table for the other two. +row+ is the row of the screen being
  # drawn: 0 to 159 is on the picture, and anything above that is the gap between pictures,
  # which is where a game does most of its setting up.
  DisplayWrite = Data.define(:kind, :address, :value, :row) do
    def on_screen? = row < 160
    def to_s = format("%-8s 0x%08X = 0x%04X  row %d", kind, address, value, row)
  end

  class Probe
    # Native pixels are 4 bytes each: byte 0 = red, 1 = green, 2 = blue,
    # 3 = unused padding (mGBA's XBGR8 color_t, little-endian).
    BYTES_PER_PIXEL = 4

    attr_reader :width, :height, :frames_run

    # WHERE THE CARTRIDGE'S SAVE MEMORY GOES, which a probe has an opinion about.
    #
    # A GBA cartridge can hold a battery-backed chip the game writes its high scores and
    # save files into, and the emulator keeps that chip as a .sav file on disk. Left to
    # itself it puts one beside the ROM it opened, and creates it if it is not there — so
    # merely LOOKING at somebody's cartridge drops a file next to it, and the second run
    # of the same ROM is not the first, because the game now finds a save. That second
    # part is the one that costs real time: it reads as the emulator being unrepeatable.
    #
    # A probe is a dev tool for asking what a ROM does, so by default it gets a temporary
    # directory of its own and takes it away again on {#close}: nothing of the caller's is
    # touched, and every run starts from a fresh cartridge. Pass +save_dir:+ to say where
    # the save really lives — a game you want to profile from its own save file wants
    # +save_dir: File.dirname(rom_path)+. {Core} keeps no opinion at all; it is the layer
    # for a caller that wants to place these itself.
    #
    # @param rom_path [String] path to a .gba (or .gb/.gbc) ROM file
    # @param save_dir [String, nil] directory for the .sav; nil for a private temporary one
    # @param bios_path [String, nil] a BIOS image to boot through, or nil for mGBA's own
    def initialize(rom_path, save_dir: nil, bios_path: nil)
      @own_save_dir = save_dir.nil? ? Dir.mktmpdir("ruby-gba-save") : nil
      @core = Core.new(rom_path, save_dir || @own_save_dir, bios_path)
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
        collect_changes if @watchers
        collect_display_writes if @display_writes
      end
      @prev_pixels = @pixels
      @pixels = @core.video_buffer
      self
    end

    # BE TOLD WHEN THE WORD AT +address+ CHANGES, instead of reading it once a frame and
    # inferring the rest.
    #
    #   probe.watch(hp_address) { |change| puts "#{change.was} -> #{change.now}" }
    #   probe.step(60)
    #
    # ...or without a block, and read {#changes} afterwards. Both work; the block is usually
    # what you want, since it puts what to do with a change next to the asking.
    #
    # Sampling cannot see a value that moved twice between looks, cannot say what it moved
    # FROM, and cannot say which write did it. For chasing "what is knocking the player's
    # health down", those are the whole question.
    #
    # WHEN THE BLOCK RUNS: after the frame the change happened in, once per change, in the
    # order they happened — not at the instant of the change itself. That instant is inside
    # the emulator with Ruby's lock released, where no Ruby can run at all. For a block that
    # reports, records or asserts, the difference does not arise; for one that wants to catch
    # the machine mid-frame and look around, it does, and it cannot.
    #
    # NOT FREE, though cheaper than it sounds: while anything is watched, every read and
    # write the game makes goes through the emulator's debugging path. Measured at about a
    # third again on a busy cartridge. A cartridge nobody asked about runs exactly as before.
    #
    # @return [self]
    def watch(address, &block)
      ensure_open!
      @core.watch(address)
      @watchers ||= {}
      @changes ||= []
      @watchers[address] = block if block
      self
    end

    # Every change seen at a watched address since the cartridge was loaded, oldest first.
    # Empty until something is watched. The first is usually the game giving the variable its
    # starting value.
    #
    # @return [Array<Change>]
    def changes
      @changes ||= []
    end

    # How many changes happened after the record filled up. A busy address moves thousands
    # of times a second, and a truncated list that does not say so reads like the whole
    # story — which is the thing watching exists to avoid.
    #
    # @return [Integer]
    def changes_missed
      ensure_open!
      @core.changes_missed
    end

    # THE SPRITES THE CONSOLE IS SHOWING, read out of its own table rather than hunted for
    # in the finished picture.
    #
    # One Hash per sprite being drawn: +:x+, +:y+, +:slot+, +:tile+, +:palette+, +:priority+,
    # +:shape+, +:size+, +:mirrored_across+, +:mirrored_down+, +:turned+. Sprites the game has
    # switched off are left out, which is the answer a test wants — the console keeps 128
    # entries whether a game uses them or not.
    #
    # Worth having because the picture cannot answer several ordinary questions: it cannot
    # tell a hidden sprite from one drawn in the backdrop colour, or from one behind a
    # background, or from one a pixel off the edge. A game with a cast of dozens asks those
    # constantly.
    #
    # @return [Array<Hash>]
    def sprites
      ensure_open!
      @core.sprites
    end

    # THE COLOURS THE CONSOLE IS DRAWING FROM — 512 of them, backgrounds first, then
    # sprites, each a 15-bit colour.
    #
    # A game fades, tints, or recolours a character by changing these rather than by
    # redrawing anything. So "did the fade happen", asked of the picture, is really a
    # question about these numbers put the long way round — and one that whatever else is on
    # screen can confuse.
    #
    # @return [Array<Integer>]
    def palette
      ensure_open!
      @core.palette
    end

    # WHERE BACKGROUND +which+ (0 to 3) IS SCROLLED TO, as [across, down] in pixels.
    #
    # The console's scroll registers are write-only: a game sets them and nothing on the
    # hardware can read them back, so a test looking at the picture can only guess how far a
    # scrolling game has travelled. The emulator kept the values it was handed.
    #
    # @return [Array(Integer, Integer)]
    def scroll(which)
      ensure_open!
      @core.scroll(which)
    end

    # BE TOLD EVERY WRITE THE GAME MAKES TO THE DISPLAY, and which row was being drawn.
    #
    #   probe.watch_display
    #   probe.step(2)
    #   probe.display_writes.select { |w| w.on_screen? }
    #
    # Everything else here reads the console once a frame, which answers everything while a
    # game sets the display up between pictures and then leaves it alone. A game that changes
    # the display WHILE the picture is being drawn cannot be seen that way at all: a
    # background bent row by row writes the same register on all 160 rows, and by the time the
    # frame ends only the last of those values is still there to read. Every earlier one is
    # gone, and so is the order they happened in.
    #
    # The record is emptied into Ruby every frame, so what {#display_writes} holds is the
    # whole run and the emulator only ever has one frame's worth. {#display_writes_missed}
    # says whether a single frame wrote more than the record could hold.
    #
    # WRITES TO THE PICTURE MEMORY ITSELF ARE LEFT OUT: what the emulator reports for one is
    # an address with no value, and a game that draws anything makes thousands of them, so
    # keeping them would bury the writes somebody asked about. Read the pictures whole
    # afterwards instead.
    #
    # NOT FREE, and dearer than watching an address: while this is on, a shim sits in front of
    # the emulator's renderer and every write to the display goes through it. Measured at
    # about two and a half times on a cartridge bending every row with a sprite moving — which
    # is close to the worst there is, since that writes the display on all 160 rows. A probe
    # that never asks pays nothing at all.
    #
    # @return [self]
    def watch_display
      ensure_open!
      @core.watch_display
      @display_writes ||= []
      self
    end

    # Every write to the display since {#watch_display} was called, oldest first.
    #
    # @return [Array<DisplayWrite>]
    def display_writes
      @display_writes ||= []
    end

    # How many writes happened after the record filled up in a single frame. A truncated list
    # that does not say so reads like the whole story.
    #
    # @return [Integer]
    def display_writes_missed
      ensure_open!
      @core.display_writes_missed
    end

    # THE LAYERS THE CONSOLE DRAWS WITH, by name — four backgrounds and the sprites.
    #
    # @return [Array<Symbol>]
    def layers
      layer_ids.keys
    end

    # THE VOICES THE CONSOLE MIXES ITS SOUND OUT OF, by name — two square voices, the wave
    # voice, the noise voice, and the two the recorded sound comes out of.
    #
    # @return [Array<Symbol>]
    def channels
      channel_ids.keys
    end

    # DRAW THE PICTURE WITHOUT SOME OF IT, so a test can ask which layer drew what.
    #
    #   probe.showing(only: :sprites) { probe.step; probe.lit_pixels }
    #   probe.showing(without: :bg1)  { probe.step; probe.pixel(44, 28) }
    #
    # The console composes one picture out of four backgrounds and the sprites, and the
    # finished picture cannot be asked which of them drew a given pixel. So "is the HUD
    # drawing at all" has no answer in it: a HUD behind the scenery, one drawn in the colour
    # already there, and one that never drew make the same picture. Leave the rest out and
    # the question is just "what is left".
    #
    # +only:+ keeps the layers named and leaves out the rest; +without:+ leaves out the ones
    # named. Either takes one name or a list.
    #
    # THE GAME IS NO LONGER QUITE THE ONE THAT SHIPS while a layer is out — this changes the
    # console, not the reading. With a block the layers go back as they were afterwards, which
    # is why the block form is the one to reach for; without one the change stands for the
    # rest of the run.
    #
    # @return [Object] the block's value, or self when there is no block
    def showing(only: nil, without: nil, &block)
      isolate(kind: :video, only: only, without: without, &block)
    end

    # MIX THE SOUND WITHOUT SOME OF IT, so a test can ask which voice sounded.
    #
    #   probe.hearing(only: :noise)   { probe.step(10); probe.audio_energy }
    #   probe.hearing(without: :wave) { probe.step(10); probe.silent? }
    #
    # A game with music under its effects mixes down to one loudness, and that number cannot
    # say which voice put what into it — so "did the explosion sound" cannot be asked of it at
    # all while the music plays. Silence the rest and it can.
    #
    # Same words and the same warning as {#showing}: +only:+ keeps, +without:+ leaves out, a
    # block puts the voices back afterwards, and while one is out the game is not sounding
    # quite as it ships.
    #
    # TAKING A VOICE OUT FROM UNDER A NOTE IT IS HOLDING IS A CUT, not a rest. The mix steps
    # down where that note was and drifts back over about half a second — the same click a
    # game gets for stopping a note dead rather than letting it fade. So a reading taken
    # straight after is a reading of the cut, and "has it gone quiet" wants half a second
    # first. Said before the note starts, there is nothing to cut and nothing to wait for.
    #
    # @return [Object] the block's value, or self when there is no block
    def hearing(only: nil, without: nil, &block)
      isolate(kind: :audio, only: only, without: without, &block)
    end

    # How many times the game has READ THE PAD since the cartridge was loaded.
    #
    # This is what the emulator saw, not how many times a game loop went round. The two look
    # alike — a game loop reads the pad once a pass — but a loop that never asks for input
    # reads it never, so this is a fact about the game asking for buttons and nothing more.
    # Counting passes wants the loop's own routine watched instead.
    #
    # @return [Integer]
    def pad_reads
      ensure_open!
      @core.pad_reads
    end

    # WHAT THE EMULATOR SAID about this cartridge — a bad read, an unmapped address, a
    # register it does not implement. Each is the kind of thing that otherwise leaves a test
    # looking at a blank screen with nothing to explain it. Quiet chatter is left out.
    #
    # @return [Array<String>]
    def complaints
      ensure_open!
      @core.complaints
    end

    # True when the core gave up on this cartridge, which otherwise looks exactly like a
    # game that drew nothing.
    def crashed?
      ensure_open!
      @core.crashed?
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

    # EVERY WRITABLE ADDRESS HOLDING +value+ RIGHT NOW.
    #
    #   probe.addresses_holding(31_336)   # the score, as it reads on screen
    #   probe.step(60)
    #   probe.narrow_to(31_332)           # the ones that moved with it
    #   probe.narrow_to(:lower)           # or: the ones that went down
    #
    # A cartridge this framework built needs none of this — the build knows where every
    # variable went and will say. A cartridge it did NOT build, which is the retail game a
    # port is being measured against, has no such record, and then the only way to an address
    # is from a number you can see on screen: look for everywhere holding it, let the game
    # run, and narrow to the places that moved the way the number did.
    #
    # Writable memory only, since a game's state is never in the cartridge.
    #
    # ONE SEARCH AT A TIME, and a look for a common number (0, or 1) matches more places than
    # are kept — so the address wanted can be missing from the very first list. Start from the
    # rarest number on screen.
    #
    # @return [Array<Integer>]
    def addresses_holding(value)
      ensure_open!
      @core.addresses_holding(value)
    end

    # Of the addresses found so far, the ones that still match.
    #
    # Give a number for "it holds this now", or one of +:lower+, +:higher+ and +:changed+ for
    # which way it moved since the last look — which is what finds a value whose number you
    # cannot read exactly, like a health bar.
    #
    # @return [Array<Integer>]
    def narrow_to(value)
      ensure_open!
      return @core.narrow_to(Core::HOLDS_THIS, value) unless value.is_a?(Symbol)

      @core.narrow_to(NARROWINGS.fetch(value) { unknown_narrowing!(value) }, 0)
    end

    # READ A WHOLE STRETCH AT ONCE, as raw bytes.
    #
    #   probe.read_bytes(guards_start, 64 * 4).unpack("V*")
    #
    # A game's state is an area of memory — a pool of sixty guards, a list, a map — and
    # asking for it a word at a time crosses into the emulator once per four bytes. The
    # crossing is what costs; the read itself is nothing. A test that reads a pool every
    # frame makes thousands of those, and a suite of such tests makes millions.
    #
    # Every address behaves as it does for {#read32} beside it, registers and unmapped
    # addresses included.
    #
    # @return [String] +count+ bytes, binary
    def read_bytes(address, count)
      ensure_open!
      @core.bus_read_bytes(address, count)
    end

    # The same stretch as whole numbers — +count+ words, each four bytes, little-endian.
    # What a run of variables or a pool's column reads as.
    #
    # @return [Array<Integer>]
    def read_words(address, count)
      read_bytes(address, count * 4).unpack("V*")
    end

    # Write a little-endian word to the address bus, into a game that is already running.
    #
    # It is how a game is put into a state somebody would otherwise have to PLAY it into:
    # set the variable holding which scene is running and the next frame is that scene, with
    # no rebuild and nobody pressing START.
    def write32(address, value)
      ensure_open!
      @core.bus_write32(address, value)
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

    # --- stopping inside a frame, for somebody debugging generated code ------
    #
    # Everything above answers what a program DID. These two answer what the processor was
    # holding while it did it, which is the question a wrong answer out of a code generator
    # comes down to: "what is in r4 at this instruction". Stop at the instruction, then read.

    # How many instructions {#run_until} runs before it gives up: several frames of a game that
    # never sleeps, which is far past any address a frame is going to reach.
    RUN_UNTIL_LIMIT = 2_000_000

    # What the processor holds right now: +:r0+ through +:r14+, +:pc+ and +:cpsr+, each an
    # unsigned 32-bit Integer. +:pc+ is the address of the instruction that runs next, which is
    # where {#run_until} stopped.
    #
    # @return [Hash{Symbol=>Integer}]
    def registers
      ensure_open!
      @core.registers
    end

    # Run one instruction at a time until the next one to run is at +address+, and stop there
    # before it runs. Raises when +limit+ instructions go by first, because a run that quietly
    # stopped somewhere else would have its registers read as if it had not.
    #
    # The picture is not refreshed: {#pixel} still shows the last whole frame {#step} ran.
    #
    # @param address [Integer] where to stop — a routine's first instruction, say
    # @return [self]
    def run_until(address, limit: RUN_UNTIL_LIMIT)
      ensure_open!
      return self if @core.run_until(address, limit)

      raise RuntimeError, format("the program did not reach 0x%08X within %d instructions", address, limit)
    end

    # Save the whole console — registers, RAM, video memory, everything — to a file, so a
    # moment can be come back to later without playing to it again.
    #
    # It is how a moment worth measuring gets captured: the boss with its health half gone,
    # the floor with sixty guards, the frame where a dozen things explode at once. Those are
    # the moments furthest from the title screen, and no held button reaches them.
    #
    # @param path [String] where to write the state
    # @return [self]
    def save_state(path)
      ensure_open!
      @core.save_state_to_file(path) or
        raise RuntimeError, "could not save the emulator state to #{path}"
      self
    end

    # Put the console back into a state saved earlier, then carry on from there.
    #
    # @param path [String] a state file written by {#save_state} or by any mGBA
    # @return [self]
    def load_state(path)
      ensure_open!
      raise ArgumentError, "there is no state file at #{path}" unless File.file?(path)

      @core.load_state_from_file(path) or
        raise RuntimeError, "could not load the emulator state in #{path}"
      self
    end

    # Which cartridge a state file was taken from, WITHOUT loading it — +{rom_crc32:, title:}+,
    # or nil when the file cannot be read as a state at all.
    #
    # A state is a snapshot of addresses, and every one of them belongs to the exact cartridge
    # it was taken from. Load one into a cartridge built a moment later and those addresses
    # point at whatever has since moved into them, which still reads as numbers — so it
    # measures rubbish quietly. mGBA itself only refuses a state from a different GAME (a
    # different title in the header) and accepts one from a different BUILD of the same game,
    # which is the case that happens constantly while a game is being written. So a caller
    # that cares has to compare this itself.
    #
    # @param path [String]
    # @return [Hash, nil]
    def state_identity(path)
      ensure_open!
      return nil unless File.file?(path)

      @core.state_file_identity(path)
    end

    # Number of pixels lit (non-black) on the current frame — a cheap
    # "is anything on screen?" measure.
    #
    # @return [Integer]
    def lit_pixels
      RubyGBAEmulator.count_changed_pixels(pixels!)
    end

    # Number of pixels that changed between the previous frame and the current
    # one. 0 before two frames have run (nothing to compare against yet).
    #
    # @return [Integer]
    def changed_pixels
      return 0 unless @pixels && @prev_pixels

      RubyGBAEmulator.count_changed_pixels(RubyGBAEmulator.xor_delta(@pixels, @prev_pixels))
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

    # Shut down the underlying core and free its buffers, and take away the temporary
    # save directory if this probe made one. Idempotent.
    def close
      @core.destroy unless @core.destroyed?
      FileUtils.remove_entry(@own_save_dir) if @own_save_dir && Dir.exist?(@own_save_dir)
      @own_save_dir = nil
      nil
    end

    # Whether the underlying core has been shut down.
    def closed?
      @core.destroyed?
    end

    private

    # WHAT THE CONSOLE'S OWN PARTS ARE CALLED HERE. mGBA's names for them are the hardware
    # manual's — +obj+ for the sprites, +ch3+ for the wave voice — which say where a thing
    # sits rather than what it is, and a test silencing +ch3+ when it meant the noise voice
    # gets no complaint from anybody. So each is given the name of what it does. The numbered
    # backgrounds keep their numbers, which is what everything else here calls them too
    # ({#scroll} takes the same 0 to 3). Anything mGBA grows that is not in here arrives under
    # the name mGBA gave it.
    LAYER_NAMES = {
      "bg0" => :bg0, "bg1" => :bg1, "bg2" => :bg2, "bg3" => :bg3, "obj" => :sprites,
      "win0" => :window0, "win1" => :window1, "objwin" => :sprite_window
    }.freeze

    CHANNEL_NAMES = {
      "ch1" => :square1, "ch2" => :square2, "ch3" => :wave, "ch4" => :noise,
      "chA" => :sample_a, "chB" => :sample_b
    }.freeze

    # What each kind is called where a person reads it: the word they wrote, and the word for
    # one of the things.
    PARTS = {
      video: { verb: "showing", what: "layer" },
      audio: { verb: "hearing", what: "sound channel" }
    }.freeze

    # Switch the named parts the way +only:+ / +without:+ asks, run the block if there is one,
    # and put everything back the way it was found.
    def isolate(kind:, only:, without:, &block)
      ensure_open!
      wanted = wanted_state(kind: kind, only: only, without: without)
      was = state_of(kind).dup
      wanted.each { |name, on| enable(kind, name, on) }
      return self unless block

      begin
        block.call(self)
      ensure
        was.each { |name, on| enable(kind, name, on) }
      end
    end

    # Which of the parts are to be on, as a name => true/false Hash covering all of them.
    def wanted_state(kind:, only:, without:)
      verb, what = PARTS.fetch(kind).values_at(:verb, :what)
      all = state_of(kind).keys
      if only.nil? == without.nil?
        raise ArgumentError,
              "#{verb} must say only: or without:. only: keeps the #{what}s you name and " \
              "leaves out the rest. without: leaves out the ones you name."
      end

      named = Array(only || without).map { |name| known!(name, all, what) }
      kept = only ? named : all - named
      all.to_h { |name| [name, kept.include?(name)] }
    end

    def known!(name, all, what)
      return name if all.include?(name)

      raise ArgumentError,
            "there is no #{what} called #{name.inspect}. The #{what}s are: #{all.join(', ')}."
    end

    # Switch one part on or off and remember which way it is set: mGBA takes the instruction
    # but cannot be asked afterwards what it took.
    def enable(kind, name, on)
      if kind == :video
        @core.enable_video_layer(layer_ids.fetch(name), on)
      else
        @core.enable_audio_channel(channel_ids.fetch(name), on)
      end
      state_of(kind)[name] = on
    end

    # Which parts are on right now. Everything the console has is on until something here
    # switches it off.
    def state_of(kind)
      if kind == :video
        @shown ||= layer_ids.keys.to_h { |name| [name, true] }
      else
        @heard ||= channel_ids.keys.to_h { |name| [name, true] }
      end
    end

    def layer_ids
      @layer_ids ||= ids_by_name(@core.video_layers, LAYER_NAMES)
    end

    def channel_ids
      @channel_ids ||= ids_by_name(@core.audio_channels, CHANNEL_NAMES)
    end

    def ids_by_name(listed, names)
      listed.to_h { |part| [names.fetch(part[:name], part[:name].to_sym), part[:id]] }
    end

    # Take the frame's changes off the core and hand each to whoever asked about that
    # address. Done once a frame rather than at the change itself, because the change
    # happens inside the emulator where no Ruby can run — and done EVERY frame so the core
    # only has to hold one frame's worth rather than a whole run's.
    def collect_changes
      fresh = @core.take_changes.map { |raw| Change.new(**raw) }
      return if fresh.empty?

      @changes.concat(fresh)
      fresh.each do |change|
        watcher = @watchers[change.address]
        watcher&.call(change)
      end
    end

    # What each number the emulator tags a write with means. The order matches the C side.
    DISPLAY_WRITE_KINDS = %i[register colour sprite].freeze

    # The ways a search can be narrowed, by the name a caller writes. The numbers behind them
    # are the emulator's own, read off it rather than written down here.
    NARROWINGS = {
      higher: Core::WENT_UP, lower: Core::WENT_DOWN, changed: Core::MOVED_AT_ALL
    }.freeze

    def unknown_narrowing!(name)
      raise ArgumentError,
            "there is no way to narrow called #{name.inspect}. Give a number the address " \
            "holds now, or one of: #{NARROWINGS.keys.join(', ')}."
    end

    # Take the frame's writes to the display off the core, for the same reason the changes
    # are taken: the emulator then only has to hold one frame's worth.
    def collect_display_writes
      fresh = @core.take_display_writes
      return if fresh.empty?

      fresh.each do |raw|
        @display_writes << DisplayWrite.new(kind: DISPLAY_WRITE_KINDS.fetch(raw[:kind]),
                                            address: raw[:address], value: raw[:value],
                                            row: raw[:row])
      end
    end

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
