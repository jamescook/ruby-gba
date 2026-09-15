# frozen_string_literal: true

module RubyGBA
  # Loads a ROM in mGBA and reads back actual rendered pixels.
  #
  # This is the definitive answer to "did my ROM actually draw anything?"
  # Instead of squinting at an emulator window, assert exact pixel values.
  #
  # Requires ruby-gba-emulator to be available (loads RubyGBAEmulator::Core) — the headless
  # libmgba probe, a gem of its own in this repository.
  #
  # @example Verify a pixel
  #   rom = RubyGBA.build("TEST") do
  #     screen :bitmap
  #     pixel 120, 80, :red
  #     halt
  #   end
  #
  #   v = RubyGBA::Verifier.new(rom)
  #   v.pixel(120, 80)        # => { r: 248, g: 0, b: 0 }
  #   v.pixel_gba(120, 80)    # => 0x001F (15-bit GBA color)
  #   v.red?(120, 80)         # => true
  #   v.black?(0, 0)          # => true (no pixel drawn there)
  #
  # @example Check a region
  #   v.all_black?                        # => false (we drew a pixel)
  #   v.region_color?(80, 50, 80, 60, :blue)  # all blue in rect?
  class Verifier
    include Constants

    # @param rom [RubyGBA::ROM] a finalized ROM
    # @param frames [Integer] how many frames to run before reading pixels (default: 2)
    # @param keys [Integer, #call, nil] held-button input for each frame — an
    #   active-high bitmask (bit per button, matching KEY_*), or a callable given
    #   the frame number returning one. nil means no buttons held.
    # @param vars [Hash{Symbol=>Integer}, nil] variable name → IWRAM address, from the
    #   backend that lowered the ROM (backend.var_addresses) — lets {#var} read a
    #   variable's value back from memory after the run.
    # @param count_passes [Boolean] count how many times round the game loop the console
    #   got, readable afterwards as {#passes}. Off by default because it is not free.
    def initialize(rom, frames: 2, keys: nil, vars: nil, count_passes: false)
      @rom = rom
      @frames = frames
      @keys = keys
      @var_addresses = vars
      @count_passes = count_passes
      @passes_counted = false
      @pixels = nil
      @audio = nil
      @audio_by_frame = nil
      @width = SCREEN_WIDTH
      @height = SCREEN_HEIGHT
      Emulator.load! # fail fast if the emulator backend isn't built
    end

    # RUN ON, so a test can watch something HAPPEN rather than only see where it ended up.
    #
    # A Verifier plays its +frames:+ the first time anything is read off it. This plays more,
    # carrying on from there, and everything read afterwards is the frame it stopped on —
    # pixels, variables, the sprites the console is drawing. What it is for is the question a
    # fixed-length run cannot put at all: which picture is showing on each frame of a knockback,
    # which colours something is drawn in while it cannot be hit, how many frames a flash lasts,
    # whether a thing vanishes and comes back.
    #
    # IT IS THE SAME OBJECT ON PURPOSE rather than a second way into the running cartridge.
    # Everything here reads the console through what the build wrote down — which of its 128
    # places each sprite was given, how far along the build moved each stored pose, where the
    # variables went — and a stepping reader without that record answers the same question
    # differently from this one, for the same frame of the same cartridge. A sprite's position
    # is the one where the two readings look equally plausible: the console's own number is the
    # picture's corner for a sprite facing one way and out by up to a canvas facing the other.
    #
    # +keys+ holds buttons while it runs — a KEY_* bitmask, or a callable given the frame
    # number. Left out, it keeps holding whatever the run was built with.
    #
    # @return [self]
    def step(count = 1, keys: nil)
      ensure_rendered!
      count.times do
        @core.set_keys(keys_for(@frames, holding: keys))
        @core.run_frame
        chunk = @core.audio_buffer
        @audio_by_frame << chunk
        @audio << chunk
        @frames += 1
      end
      @pixels = @core.video_buffer
      self
    end

    # Get the 8-bit RGB color at a screen coordinate.
    # @return [Hash] { r:, g:, b: } with 0-255 values
    def pixel(x, y)
      ensure_rendered!
      validate_coords!(x, y)
      idx = (y * @width + x) * 4
      # mGBA native format is XBGR8 (0xXXBBGGRR) — R in low byte
      r = @pixels.getbyte(idx)
      g = @pixels.getbyte(idx + 1)
      b = @pixels.getbyte(idx + 2)
      { r: r, g: g, b: b }
    end

    # Get the 15-bit GBA color at a screen coordinate.
    # Quantizes 8-bit channels back to 5-bit for easy comparison
    # with GBA color constants.
    # @return [Integer] 15-bit BGR555 color
    def pixel_gba(x, y)
      c = pixel(x, y)
      (c[:r] >> 3) | ((c[:g] >> 3) << 5) | ((c[:b] >> 3) << 10)
    end

    # Check if a pixel matches a named color (within GBA 5-bit precision).
    # @param x [Integer] screen x
    # @param y [Integer] screen y
    # @param color [Symbol, Integer] color name or 15-bit value
    # @return [Boolean]
    def pixel_is?(x, y, color)
      expected = Color.resolve(color)
      pixel_gba(x, y) == expected
    end

    # Convenience color checks
    def black?(x, y) = pixel_is?(x, y, :black)
    def white?(x, y) = pixel_is?(x, y, :white)
    def red?(x, y)   = pixel_is?(x, y, :red)
    def green?(x, y) = pixel_is?(x, y, :green)
    def blue?(x, y)  = pixel_is?(x, y, :blue)

    # The whole rendered frame as 15-bit GBA colors, row-major (index = y*240 + x).
    #
    # {#pixel_gba} answers "what color is this one pixel?"; this answers "what does
    # the whole screen look like?" in one pass, which is what a frame-to-frame
    # comparison needs — asking pixel by pixel would mean 38,400 separate reads.
    # The values line up with the reference interpreter's own framebuffer dump, so
    # the two backends' pictures can be compared directly.
    # @return [Array<Integer>] 240*160 colors in BGR555
    def frame_gba
      ensure_rendered!
      # mGBA gives us one 32-bit word per pixel as XBGR8 (0xXXBBGGRR): red in the
      # low byte, then green, then blue. The GBA itself stores 5 bits per channel,
      # so shift each 8-bit channel back down to the 15-bit color the ROM asked for.
      @pixels.unpack("V*").map! do |word|
        r = word & 0xFF
        g = (word >> 8) & 0xFF
        b = (word >> 16) & 0xFF
        (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
      end
    end

    # Check if the entire screen is black (nothing rendered).
    def all_black?
      ensure_rendered!
      @pixels.bytes.each_slice(4).all? { |r, g, b, _| r == 0 && g == 0 && b == 0 }
    end

    # Check if every pixel in a rectangle matches a color.
    # @return [Boolean]
    def region_color?(x, y, w, h, color)
      expected = Color.resolve(color)
      h.times do |dy|
        w.times do |dx|
          return false unless pixel_gba(x + dx, y + dy) == expected
        end
      end
      true
    end

    # Find the first pixel that doesn't match the expected color in a region.
    # Useful for debugging — tells you exactly where the mismatch is.
    # @return [Hash, nil] { x:, y:, expected:, actual: } or nil if all match
    def region_mismatch(x, y, w, h, color)
      expected = Color.resolve(color)
      h.times do |dy|
        w.times do |dx|
          px = x + dx
          py = y + dy
          actual = pixel_gba(px, py)
          if actual != expected
            return { x: px, y: py,
                     expected: format("0x%04X", expected),
                     actual: format("0x%04X", actual),
                     actual_rgb: pixel(px, py) }
          end
        end
      end
      nil
    end

    # --- memory ---
    #
    # Read values back out of the running console, not just the screen. The emulator reads
    # the GBA bus directly, so a hardware test can assert run-time STATE — a variable
    # a program computed, or a hardware register like VCOUNT — the same way it asserts
    # pixels. Reads happen at the final frame boundary (after the frames have run).

    # Read a 32-bit word off the GBA bus at +address+ — an IWRAM variable, or a
    # memory-mapped register. (VCOUNT, the current scanline, is a 16-bit register at
    # 0x04000006; use {#mem16} for it.)
    def mem32(address)
      ensure_rendered!
      @core.bus_read32(address)
    end

    # Read a 16-bit halfword off the GBA bus at +address+.
    def mem16(address)
      ensure_rendered!
      @core.bus_read16(address)
    end

    # Read a single byte off the GBA bus at +address+.
    def mem8(address)
      ensure_rendered!
      @core.bus_read8(address)
    end

    # How many times the game read the pad while the console ran it — what the emulator saw,
    # which is not the same as how many passes a game loop made (see Probe#pad_reads).
    #
    # @return [Integer]
    def pad_reads
      ensure_rendered!
      @core.pad_reads
    end

    # Read a program variable's value from IWRAM, by name. Needs the variable-address
    # map from the backend that lowered the ROM — construct the Verifier with
    # `vars: backend.var_addresses`. This is how a test asserts what a program
    # actually computed on real hardware.
    def var(name)
      unless @var_addresses
        raise ArgumentError,
              "no variable map given — build the Verifier with `vars: backend.var_addresses` to read a variable"
      end
      address = @var_addresses[name] ||
                raise(ArgumentError, "unknown variable #{name.inspect} — known: #{@var_addresses.keys.join(', ')}")
      mem32(address)
    end

    # THE SPRITES THE CONSOLE IS DRAWING, each knowing which one the game declared it for.
    #
    # One Hash per sprite being drawn, off the console's own table — +:name+, +:x+, +:y+,
    # +:slot+, +:tile+, +:palette+, +:priority+, +:shape+, +:size+, +:mirrored_across+,
    # +:mirrored_down+, +:turned+, +:piece_x+, +:piece_y+. Name one and only that sprite's rows
    # come back.
    #
    # +:x+ AND +:y+ ARE WHERE THE PICTURE STARTS — the corner of the canvas the art was drawn
    # on, which is where the game put the sprite. That is NOT the number the console carries,
    # and the difference is worth saying because it is invisible: a pose is stored trimmed to
    # what it actually draws and the sprite stands that much further along to compensate, and a
    # pose drawn backwards is trimmed from the other side and stands a different amount further
    # along again. So the console's own number is right for a sprite facing one way and out by
    # up to a canvas for the same sprite facing the other — which reads as the animation being
    # wrong rather than the position. The build did the moving, so it is undone here; +piece_x+
    # and +piece_y+ still carry what the console was told, for a test that wants that instead.
    # A row the build cannot name is left where it is, since there is nothing to look up.
    #
    # Worth having because the finished picture cannot answer several ordinary questions: it
    # cannot tell a hidden sprite from one drawn in the backdrop colour, from one behind a
    # background, or from one a pixel off the edge. A sprite the game has switched off is left
    # out, which is the answer a test wants.
    #
    # WHAT THE NAME SAVES is the guessing. The console's table says which of its 128 places a
    # sprite is in and nothing else, so a test with a cast otherwise picks its hero by a place
    # number (which moves the day the game declares something earlier), by position (which
    # needs the game to keep its own position in a variable, and is a pixel or two out exactly
    # while the thing is moving), or by which colours it draws from (no use at all for a sprite
    # whose colours are being swapped). The build gave out the places and the cartridge carries
    # that, so the rows can say whose they are.
    #
    # A PICTURE TOO BIG for the console to draw in one go is several rows with the same name,
    # not one merged row: which piece is which is the framework's business, and a test asking
    # where something is wants all of it.
    #
    # Rows the build cannot name come back with a nil +:name+ — a glyph of tiled text, say.
    #
    # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
    # @return [Array<Hash>]
    def sprites(name = nil)
      rows = every_sprite
      return rows if name.nil?

      known = sprite_slots!
      unless known.key?(name)
        raise ArgumentError, "This game has no sprite #{name.inspect}. " \
                             "Its sprites are: #{known.keys.map(&:inspect).join(', ')}."
      end
      rows.select { |row| row[:name] == name }
    end

    # HOW MANY TIMES ROUND THE GAME LOOP THE CONSOLE GOT, in the frames it ran. Build the
    # Verifier with `count_passes: true` to ask for it.
    #
    # This is not the frame count, and the difference is the reason it exists: the console
    # runs the loop once per frame it has TIME for, so a game whose pass does not fit in a
    # frame plays less game per frame than one that does. Anything lining this run up against
    # a run somewhere else — the interpreter, an earlier build — has to line up on passes.
    #
    # It is counted by watching for the loop's own first instruction, so the cartridge
    # measured is the cartridge that ships. The alternative is adding a counter to the
    # program, and one extra instruction can tip a routine out of the console's quick memory
    # and change the timing being measured.
    #
    # PASSES FINISHED, not passes begun. A run stops at a frame boundary, where the game is
    # part-way through a pass — it has asked for the next frame and is waiting for it — so
    # the pass in flight is not counted. A program with no game loop has no passes and gets
    # nil, which is a different answer from none.
    #
    # WHICH INSTRUCTION IS WATCHED depends on where the build put the loop, and the two
    # answers are chosen so that neither has to guess where the game is when the run stops.
    #
    # A loop the build kept in the console's quick memory is a routine the loop CALLS, so its
    # first instruction runs once at the START of every pass — the one in flight included, and
    # there is always one in flight. Passes finished is then one fewer than the arrivals.
    #
    # A loop left in the cartridge is written out in place, and the instruction that makes it
    # a loop is the branch back to the top. That runs once at the END of every pass that
    # finished, and never for the one in flight, so the arrivals ARE the passes finished. Its
    # first instruction cannot be used instead: for a loop that waits for the screen, that is
    # the instruction asking the console to sleep, and the console's own startup can enter
    # that one twice.
    def passes
      unless @count_passes
        raise ArgumentError,
              "this run did not count passes — build the Verifier with `count_passes: true` to count them"
      end
      ensure_rendered!
      return nil unless @passes_counted

      [@core.arrivals - @pass_in_flight, 0].max
    end

    # --- the processor ---
    #
    # For debugging what the lowering emitted: stop the running cartridge at the first
    # instruction of a routine, then read what the processor holds there. The frames run
    # first, so the stop is the next time the routine is reached after them.

    # How many instructions {#run_until} runs before it gives up: several frames of a game
    # that never sleeps.
    RUN_UNTIL_LIMIT = 2_000_000

    # Run on until the routine named +routine+ is about to run its first instruction. The
    # name is the one the program gave it (`func(:count_up)`), or BuildRecord::FRAME_ROUTINE
    # for the game loop's own body. Raises when the routine is never reached, rather than
    # leaving the processor somewhere else to be read as if it were there.
    def run_until(routine, limit: RUN_UNTIL_LIMIT)
      ensure_rendered!
      address = routine_start!(routine)
      return self if @core.run_until(address, limit)

      raise RuntimeError, format("The routine %p (at 0x%08X) did not run within %d instructions.",
                                 routine, address, limit)
    end

    # What the processor holds right now: +:r0+ through +:r14+, +:pc+ (the instruction that
    # runs next) and +:cpsr+.
    def registers
      ensure_rendered!
      @core.registers
    end

    # WHAT THE CONSOLE IS PLAYING, as values — one per sounding voice, in the order the
    # mixer holds them (see IR::Backends::GBA::Mixer::Voice for what each carries). Read off
    # the running console at the final frame boundary, so it is what the lowering really did
    # rather than what anything says it should have.
    #
    # Needs the cartridge to know where its voices are kept, which it does when it was
    # assembled with its build record. A program that plays no samples has no voices, and
    # this is empty for it.
    def voices
      table = voice_table!
      table ? table.read { |address| mem32(address) } : []
    end

    # Just the names of the samples sounding, in the mixer's order — directly comparable with
    # the interpreter's Reference#active_samples, which is what lets a test check the two
    # backends agree about sound with one equality.
    def sounding = voices.map(&:sample)

    # The sample clock this cartridge was built with — the rate the mix runs at and how many
    # samples that is a frame. A voice's step is a ratio against this rate, so anything asking
    # what pitch a voice is playing at needs it. Nil for a program that plays no samples.
    def sample_clock = voice_table!&.clock

    # WHAT THE CONSOLE COULD NOT PLAY: how many plays found every voice busy and were dropped,
    # and how the voices were being split at the worst of them. Counted since the cartridge
    # booted, so a test reads it at the end of a run. Directly comparable with the
    # interpreter's Reference#sound_drops — the same shape, so the two backends' answers meet
    # in one equality. Unmeasured for a program that plays no samples, which can lose none.
    def sound_drops
      table = drop_table!
      table ? table.read { |address| mem32(address) } : SoundDrops::Reading.unmeasured
    end

    # --- audio ---
    #
    # The counterpart to reading pixels: read the sound that actually came out.
    # The emulator mixes each frame to stereo PCM and we concatenate the whole run, so
    # these ask "what did the speaker do?" rather than trusting the ROM's bytes.

    # Total absolute amplitude across every PCM sample captured — 0 is perfect
    # silence. A deliberately crude "did any sound come out?" measure that doesn't
    # care about pitch or waveform, only whether the hardware made noise.
    def audio_energy
      ensure_rendered!
      @audio.unpack("s<*").sum(&:abs)
    end

    # The sound itself: one Integer per 16-bit sample, the two channels interleaved.
    #
    # What this answers that #audio_energy cannot is what SHAPE the sound had. A break in the
    # stream — the mixer handing the hardware a buffer that does not line up with what it eats
    # — is a jump from one sample to the next, and a run full of them has exactly the same
    # total energy as a clean one.
    def audio_samples
      ensure_rendered!
      @audio.unpack("s<*")
    end

    # True when the run produced no sound at all (energy exactly 0).
    def silent?
      audio_energy.zero?
    end

    # True when the run produced any sound.
    def sound?
      !silent?
    end

    # ...and the same figure FRAME BY FRAME: one energy per displayed frame, in order.
    #
    # What this answers that #audio_energy cannot is whether the sound arrived EVENLY. A game
    # that hands the hardware sound more slowly than the hardware plays it still makes plenty
    # of noise over a run — the total says nothing — but the noise comes in bursts with holes
    # between them, and a run of frames with far less energy than their neighbours is what a
    # hole looks like from here.
    def audio_energy_by_frame
      ensure_rendered!
      @audio_by_frame.map { |chunk| chunk.unpack("s<*").sum(&:abs) }
    end

    # Dump a text grid showing what colors are on screen.
    # Each character represents an 8x8 tile area.
    # @return [String] visual map of the screen
    def screen_map(tile_size: 8)
      ensure_rendered!
      lines = []
      (@height / tile_size).times do |ty|
        row = +""
        (@width / tile_size).times do |tx|
          # Sample center of each tile
          sx = tx * tile_size + tile_size / 2
          sy = ty * tile_size + tile_size / 2
          c = pixel_gba(sx, sy)
          row << color_char(c)
        end
        lines << row
      end
      lines.join("\n")
    end

    # Summary report of what's on screen.
    # @return [String]
    def report
      ensure_rendered!
      lines = []
      lines << "=== Frame Verifier Report ==="
      lines << "  Frames rendered: #{@frames}"

      # Count unique colors
      colors = Hash.new(0)
      (@height).times do |y|
        (@width).times do |x|
          colors[pixel_gba(x, y)] += 1
        end
      end

      total = @width * @height
      lines << "  Unique colors: #{colors.size}"
      colors.sort_by { |_, count| -count }.first(10).each do |color, count|
        pct = (count * 100.0 / total).round(1)
        name = color_name(color)
        lines << "    0x#{format('%04X', color)} #{name}: #{count} pixels (#{pct}%)"
      end

      lines << "  Screen map (8x8 tiles):"
      screen_map.each_line { |l| lines << "    #{l}" }

      lines.join("\n")
    end

    private

    # The cartridge's record of where it keeps its voices, or nil for a program that plays no
    # samples. A cartridge assembled without its build record cannot answer, and that is a
    # setup mistake in the test rather than a fact about the sound — so it says how to fix it.
    def voice_table!
      unless @rom.built
        raise ArgumentError,
              "This ROM does not know where it keeps its voices. Assemble it with its build " \
              "record, then read the voices: ROM.assemble(code, ..., built: backend.build_record(program))."
      end
      @rom.built.voices
    end

    # Every row of the console's table, each with the name of the sprite the game declared it
    # for. Read once per call, so a test that steps the cartridge on sees where things moved to.
    def every_sprite
      ensure_rendered!
      whose = sprite_slots!.each_with_object({}) do |(name, slots), by_slot|
        slots.each { |slot| by_slot[slot] = name }
      end
      moved = @rom.built.sprite_offsets
      @core.sprites.map do |row|
        name = whose[row[:slot]]
        dx, dy = moved.dig(row[:slot], [row[:tile], row[:mirrored_across]]) || [0, 0]
        # Back into the ranges the console keeps these in, so a sprite half off the left edge
        # reads the way its own place reads rather than going negative.
        row.merge(name: name, piece_x: row[:x], piece_y: row[:y],
                  x: (row[:x] - dx) & 0x1FF, y: (row[:y] - dy) & 0xFF)
      end
    end

    # Which places the build gave each declared sprite. A cartridge assembled without its
    # build record cannot say, and that is a setup mistake in the test rather than a fact
    # about the game — so it says how to fix it.
    def sprite_slots!
      unless @rom.built
        raise ArgumentError,
              "This ROM does not know which of its sprites is which. Assemble it with its build " \
              "record: ROM.assemble(code, ..., built: backend.build_record(program))."
      end
      @rom.built.sprite_slots
    end

    # Where a routine's first instruction really is while the cartridge runs — which is not
    # where it sits in the cartridge when it was copied into the console's quick memory, so
    # only the build record can say.
    def routine_start!(routine)
      unless @rom.built
        raise ArgumentError,
              "This ROM does not know where its routines are. Assemble it with its build record: " \
              "ROM.assemble(code, ..., built: backend.build_record(program))."
      end
      span = @rom.built.routines[routine] or
        raise ArgumentError, "This ROM has no routine #{routine.inspect}. " \
                             "Its routines are: #{@rom.built.routines.keys.map(&:inspect).join(', ')}."
      span.begin
    end

    # ...and where it counts what it could not play. Same rule: only the build knows, because
    # the counters are hidden variables.
    def drop_table!
      unless @rom.built
        raise ArgumentError,
              "This ROM does not know where it counts the sounds it dropped. Assemble it with " \
              "its build record: ROM.assemble(code, ..., built: backend.build_record(program))."
      end
      @rom.built.sound_drops
    end

    # Where the cartridge's save memory goes: one directory for the whole process, made on
    # first use and taken away when the process ends.
    #
    # A GBA cartridge can carry a chip the game saves into, which the emulator keeps as a
    # .sav file. Left alone it writes that file beside the ROM and creates it whether the
    # game saves anything or not, so a suite that verifies thousands of ROMs abandons
    # thousands of save files. One directory is enough to hold them all, because every ROM
    # here is written to a uniquely named temp file and its save takes that name too.
    #
    # Per process rather than per Verifier on purpose. Tying it to one object means
    # removing it when that object is collected, and a Verifier still alive at exit is
    # never collected — so a suite leaves behind exactly the ones garbage collection did
    # not get round to. Exit is the moment that always arrives.
    def self.save_dir
      @save_dir ||= begin
        require "tmpdir"
        require "fileutils"
        dir = Dir.mktmpdir("verify-save")
        at_exit { FileUtils.remove_entry(dir, true) }
        dir
      end
    end

    def ensure_rendered!
      return if @pixels

      # Write ROM to a temp file, load in mGBA, run frames, read back the final
      # frame's pixels and the whole run's audio. Audio drains per frame, so we
      # concatenate each frame's chunk to hear the entire run, not just the last.
      require "tempfile"
      # Keep the core (and its ROM file) alive on the instance rather than tearing
      # them down here: memory reads (#mem32 / #var) run against the same core after
      # the frames, at the final frame boundary. Both are released when this Verifier
      # is garbage-collected.
      @tempfile = Tempfile.new(["verify", ".gba"])
      @tempfile.binmode
      @rom.write(@tempfile.path)
      @tempfile.flush
      @core = Emulator.open(@tempfile.path, save_dir: self.class.save_dir)
      count_the_passes if @count_passes
      @audio = +"".b
      @audio_by_frame = []
      @frames.times do |frame|
        @core.set_keys(keys_for(frame)) if @keys
        @core.run_frame
        chunk = @core.audio_buffer
        @audio_by_frame << chunk
        @audio << chunk
      end
      @pixels = @core.video_buffer
    end

    # Watch for arrivals at the game loop's first instruction, before any frame runs. A
    # program with no game loop has no such routine, and that is an answer rather than an
    # error — see {#passes}.
    def count_the_passes
      unless @rom.built
        raise ArgumentError,
              "This ROM does not know where its game loop is, so its passes cannot be counted. " \
              "Assemble it with its build record: ROM.assemble(code, ..., built: backend.build_record(program))."
      end
      span = @rom.built.routines[BuildRecord::FRAME_ROUTINE]
      return unless span

      # The start of the pass, or the end of it — see {#passes} for why each shape gets the
      # one it does, and what each means for the pass that is still running when we stop.
      kept_fast = @rom.built.fast_frame?
      @pass_in_flight = kept_fast ? 1 : 0
      @core.watch_arrivals(kept_fast ? span.begin : span.end)
      @passes_counted = true
    end

    # The held-button bitmask for a given frame: what a step was told to hold, else what the
    # run was built with, else nothing.
    def keys_for(frame, holding: nil)
      held = holding || @keys
      return 0 unless held

      held.respond_to?(:call) ? held.call(frame) : held
    end

    def validate_coords!(x, y)
      raise ArgumentError, "x=#{x} out of range (0-#{@width - 1})" unless (0...@width).cover?(x)
      raise ArgumentError, "y=#{y} out of range (0-#{@height - 1})" unless (0...@height).cover?(y)
    end

    def color_char(gba_color)
      case gba_color
      when 0x0000 then "."  # black
      when 0x7FFF then "#"  # white
      when 0x001F then "R"  # red
      when 0x03E0 then "G"  # green
      when 0x7C00 then "B"  # blue
      when 0x03FF then "Y"  # yellow
      when 0x7FE0 then "C"  # cyan
      when 0x7C1F then "M"  # magenta
      else "?"              # other
      end
    end

    def color_name(gba_color)
      Color::PRESETS.each do |name, val|
        return "(#{name})" if val == gba_color
      end
      ""
    end
  end
end
