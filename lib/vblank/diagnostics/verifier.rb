# frozen_string_literal: true

# REQUIRED HERE AND NOT WHERE THEY ARE USED, which is the opposite of the usual advice about
# a cost you may not pay. Asking for a file reads the list of places Ruby looks for one, and
# that list is a global — which a worker may not read at all. So a `require` reached while a
# cartridge is being verified stops the run, and these are on that path: a verified ROM goes
# through a temporary file every time.
require "tempfile"
require "tmpdir"
require "fileutils"

module VBlank
  module Diagnostics
    # Loads a ROM in mGBA and reads back actual rendered pixels.
    #
    # This is the definitive answer to "did my ROM actually draw anything?"
    # Instead of squinting at an emulator window, assert exact pixel values.
    #
    # ONE READER FOR EVERY CONSOLE. The picture, memory by address, the variables, the save
    # memory, the sound that came out, playing on, and leaving layers or voices out are read the
    # same way whichever console a cartridge is for, and are read here. What a console keeps its
    # own way — which sprite is whose, how its colours are laid out, how it counts its passes, its
    # mixer of recordings, the processor — a reader is given when it is made, from the module its
    # console's kit names (Console::Kit#reading: AdvanceReading, ColorReading). A reader over one
    # console's cartridge has only the questions that console answers: a Color reader has no
    # `registers`, rather than one that is asked and refuses, and no question is ever answered with
    # another console's layout, which would come back as a number and a wrong one.
    #
    # Requires ruby-gba-emulator to be available (loads RubyGBAEmulator::Core) — the headless
    # libmgba probe, a gem of its own in this repository.
    #
    # @example Verify a pixel
    #   rom = VBlank.build("TEST", console: :gba) do
    #     screen :bitmap
    #     pixel 120, 80, :red
    #     halt
    #   end
    #
    #   v = VBlank::Diagnostics::Verifier.new(rom)
    #   v.pixel(120, 80)        # => { r: 248, g: 0, b: 0 }
    #   v.pixel_gba(120, 80)    # => 0x001F (15-bit GBA color)
    #   v.red?(120, 80)         # => true
    #   v.black?(0, 0)          # => true (no pixel drawn there)
    #
    # @example Check a region
    #   v.all_black?                        # => false (we drew a pixel)
    #   v.region_color?(80, 50, 80, 60, :blue)  # all blue in rect?
    class Verifier
      # HOW A CONSOLE'S COLOURS ARE LAID OUT (see #palette): the backgrounds' half first, then the
      # sprites', each +half+ colours long and in groups of +group+, the most one sprite or one
      # square of background draws from. Each console's part of the reader says its own.
      PaletteLayout = Data.define(:half, :group) do
        def halves = { backgrounds: 0, sprites: half }
      end

      # WHERE A CARTRIDGE'S SAVE MEMORY ENDS IN THE FILE THE EMULATOR KEEPS IT IN (see #save_image).
      # A cartridge with a clock has the emulator write the clock's own state after the save
      # memory, +clock_bytes+ of it. The save memory is a whole number of +whole+-byte pieces, so
      # what is over is the clock's, and that alone says whether the cartridge had one. Each
      # console's part of the reader says its own.
      SaveFileLayout = Data.define(:whole, :clock_bytes) do
        # The save memory in +file+ (the bytes of the emulator's file), without the clock's bytes.
        def memory_in(file)
          return file unless file.bytesize % whole == clock_bytes

          file.byteslice(0, file.bytesize - clock_bytes)
        end
      end

      # @param rom [VBlank::Cartridge::ROM, VBlank::Cartridge::GBCROM] a finished cartridge
      # @param frames [Integer] how many frames to run before reading pixels (default: 2)
      # @param keys [Integer, #call, nil] held-button input for each frame — an
      #   active-high bitmask (bit per button, matching Console::Hardware::KEY_*), or a callable given
      #   the frame number returning one. nil means no buttons held.
      # @param vars [Hash{Symbol=>Integer}, nil] variable name → IWRAM address, from the
      #   backend that lowered the ROM (backend.var_addresses) — lets {#var} read a
      #   variable's value back from memory after the run.
      # @param count_passes [Boolean] count how many times round the game loop the console
      #   got, readable afterwards as {#passes}. Off by default because it is not free.
      # @param save [IR::SaveImage, nil] what the cartridge's save memory holds when the console
      #   is turned on — the same save memory the interpreter reads and writes, so a save one
      #   backend wrote can be handed to the other. nil is a fresh chip.
      # @param sound [RecordedSound] where the sound of the run is kept. Left out, the reader
      #   holds a minute of play in memory and writes older sound to a scratch file in the
      #   machine's temporary files. Hand one over to say how many frames are held, or where
      #   the file goes: `sound: RecordedSound.new(frames_in_memory: 600, folder: "scratch")`.
      #   Every sound reader answers for the whole run either way.
      # +clock:+ (a Time) gives the cartridge a clock chip reading that moment at power-on and
      # moving on a console frame each frame, the emulator's own and never the computer's (see
      # RubyGBAEmulator::Probe#clock_at); left out, the cartridge has none, as on most emulators.
      # +clock_set: false+ makes it a chip whose battery ran out.
      def initialize(rom, frames: 2, keys: nil, vars: nil, count_passes: false, save: nil, sound: RecordedSound.new,
                     clock: nil, clock_set: true)
        refuse_sound_not_recorded_sound!(sound)
        @rom = rom
        @save = save
        @clock = clock
        @clock_set = clock_set
        @frames = frames
        @keys = keys
        @var_addresses = vars
        @count_passes = count_passes
        # What only this cartridge's console answers, read its own way (see "what each console's
        # cartridge is asked its own way" below).
        @reading = Console.for(rom.console).reading
        extend @reading
        @rendered = false
        @played = 0
        @pixels = nil
        @sound = sound
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
      # +keys+ holds buttons while it runs — a Console::Hardware::KEY_* bitmask, or a callable given the frame
      # number. Left out, it keeps holding whatever the run was built with.
      #
      # @return [self]
      def step(count = 1, keys: nil)
        ensure_rendered!
        play(count, holding: keys)
        self
      end

      # Get the 8-bit RGB color at a screen coordinate.
      # @return [Hash] { r:, g:, b: } with 0-255 values
      def pixel(x, y)
        held = picture
        validate_coords!(x, y)
        idx = (y * @width + x) * 4
        # mGBA native format is XBGR8 (0xXXBBGGRR) — R in low byte
        { r: held.getbyte(idx), g: held.getbyte(idx + 1), b: held.getbyte(idx + 2) }
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
        expected = Graphics::Color.resolve(color)
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
      # @return [Array<Integer>] screen_width * screen_height colors in BGR555
      def frame_gba = Emulator.screen_questions.color_list(picture)

      # How wide and tall the console's picture is, in pixels: the size the emulator draws for
      # the cartridge it was handed, which is 240 by 160 for an Advance cartridge.
      def screen_width
        ensure_rendered!
        @width
      end

      def screen_height
        ensure_rendered!
        @height
      end

      # --- questions about the whole screen ---
      #
      # THE EMULATOR ANSWERS THESE, in one pass over the picture (see
      # {Emulator.screen_questions}). Going through the pixels in Ruby is a number made and
      # thrown away for every one of them, which is far more work than running the frame
      # was, so a test that asks something of the whole screen on every frame of a long run
      # was spending nearly all of its time asking.
      #
      # THEY ARE ANSWERED AT THE PRECISION A CONSOLE SHOWS, the same fifteen bits
      # {#pixel_gba} reads: five each of red, green and blue. The emulator keeps eight, and
      # what it holds below the five is its own working — it fills a palette colour's low
      # bits in one way, and works a colour the display brightened, darkened or mixed out at
      # eight bits. So it can hold the same five-bit colour as two different numbers, and
      # two pictures that are different bytes can still be one picture here.

      # The whole screen as the console's 15-bit colours in ONE STRING: two bytes a pixel,
      # low byte first, a row at a time from the top. It is {#frame_gba} without the list —
      # what to keep a still as, or to hash one, and the same bytes for the same picture, so
      # two of them are compared with `==`. A list of 38,400 numbers costs many times what
      # the string does, so reach for the list to look pixels up in and for this to keep.
      # It is not a {#picture}: {#same_picture_as?} does not take one.
      #
      # @return [String]
      def frame_colors = Emulator.screen_questions.colors(picture)

      # The one colour every pixel is, as a 15-bit number, or nil when the screen holds more
      # than one: `only_color == Color.resolve(:white)` is a flash at its brightest.
      #
      # @return [Integer, nil]
      def only_color = Emulator.screen_questions.only_color(picture)

      # How bright the screen is: every pixel's red, green and blue added up, each as the
      # level a console shows, 0 to 31. One number that rises and falls with a fade, which
      # is what watching one frame by frame wants.
      #
      # @return [Integer]
      def brightness = Emulator.screen_questions.brightness(picture)

      # Whether this reader is showing THE SAME PICTURE as +other+: every pixel the same
      # colour. +other+ is another running cartridge, or a {#picture} kept from earlier.
      #
      # Two cartridges played side by side are asked this after every frame, so it has to
      # cost next to nothing, and it does: two pictures the emulator holds as the same bytes
      # are known to be the same in one comparison of the bytes.
      #
      # It is the colours and nothing else. The same picture built by a different part of
      # the display — a background where the other has a sprite — is the same picture, and
      # so is one the emulator holds as different numbers below the five bits.
      def same_picture_as?(other) = Emulator.screen_questions.same?(picture, picture_of(other))

      # HOW this reader's picture differs from +other+'s — another running cartridge, or a
      # {#picture} kept from earlier — or nil when the two are one picture:
      #
      #   { count: 32,                  # how many pixels are a different colour
      #     box: [20, 60, 10, 8],       # the part of the screen they all lie in: x, y, width, height
      #     at: [20, 60],               # the first of them, a row at a time from the top
      #     colors: [0x7C00, 0x7FFF] }  # that pixel's colour here, and its colour there
      #
      # +looked_at+ leaves part of the screen out: a string of one byte for each pixel, a row
      # at a time, nought for a pixel that is not looked at. A pixel left out is not counted,
      # is not in the box and is never the first.
      #
      # @return [Hash, nil]
      def difference_from(other, looked_at: nil)
        Emulator.screen_questions.difference(picture, picture_of(other), @width, looked_at)
      end

      # THE PICTURE ON SCREEN AS THE EMULATOR HOLDS IT — the frame the run stopped on — to
      # keep and compare a later one against: `kept = game.picture`, and some frames on,
      # `game.same_picture_as?(kept)`. Four bytes a pixel: red, green, blue and a byte of
      # nothing. It is the emulator's own numbers and not the colours a console shows;
      # {#frame_colors} is those. It cannot be changed, and each frame played makes a new
      # one, so one that was kept stays as it was.
      #
      # A run told to play no frames has no picture, which is a friendly error rather than a
      # crash on nothing: the console draws when it is run, so there is nothing to read
      # until it has been.
      #
      # @return [String]
      def picture
        ensure_rendered!
        @pixels || raise(RuntimeError,
                         "This run has played no frames, so there is no picture to read. " \
                         "Give the Verifier `frames:` of 1 or more, or call `step` first.")
      end

      # Check if the entire screen is black (nothing rendered).
      #
      # THIS ONE IS ASKED OF WHAT THE EMULATOR HOLDS, eight bits a channel, and so it is
      # finer than the rest: a pixel the display has darkened to almost nothing is black to
      # {#black?} and to {#only_color}, and is not black to this. It is left that way so that
      # the frame a fade is called over on does not move for anybody already asking.
      def all_black? = Emulator.screen_questions.only_color(picture, 8) == 0

      # Check if every pixel in a rectangle matches a color.
      # @return [Boolean]
      def region_color?(x, y, w, h, color)
        expected = Graphics::Color.resolve(color)
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
        expected = Graphics::Color.resolve(color)
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
        @probe.read32(address)
      end

      # Read a 16-bit halfword off the GBA bus at +address+.
      def mem16(address)
        ensure_rendered!
        @probe.read16(address)
      end

      # Read a single byte off the GBA bus at +address+.
      def mem8(address)
        ensure_rendered!
        @probe.read8(address)
      end

      # THE SAVE CHIP AS IT IS NOW, as an IR::SaveImage the size the chip is — which is what
      # turning the console off leaves. Hand it to another run's `save:` to turn it on again.
      #
      # The bus shows a 128K flash chip a bank at a time, so the chip is read from the file the
      # emulator keeps it in, which holds all of it. A cartridge with no save chip has nothing
      # in that file, and nil is what it hands back.
      #
      # A cartridge with a clock keeps that clock's own state in the same file, after the save
      # chip, and those bytes are the clock's and not the save chip's, so they are left out. How
      # many there are is the console's (SaveFileLayout). A cartridge with a clock and no save
      # chip has only the clock's bytes there, and hands back nil too.
      def save_image
        memory = save_bytes&.then { |bytes| @reading::SAVE_FILE.memory_in(bytes) }
        return nil if memory.nil? || memory.empty?

        IR::SaveImage.from_sav(memory, from: "The bytes of this cartridge's save memory")
      end

      # The save chip as it is now, as the bytes of the file the emulator keeps it in, or nil
      # for a cartridge with no save chip. This is every chip there is, whatever its size;
      # {#save_image} is the same bytes as a chip the framework has a model of.
      def save_bytes
        ensure_rendered!
        File.binread(save_path) if File.size?(save_path)
      end

      # Read a program variable's value from IWRAM, by name. Needs the variable-address
      # map from the backend that lowered the ROM — construct the Verifier with
      # `vars: backend.var_addresses`. This is how a test asserts what a program
      # actually computed on real hardware.
      #
      # IT IS THE NUMBER THE PROGRAM COUNTED TO, which means a count taken below nothing comes
      # back below nothing. A variable here is a signed whole number by definition (see
      # IR::Int32, the contract every backend keeps), so there is nothing to ask and nothing to
      # guess: the word in memory holds no sign, and reading it out means putting the sign back.
      # Worth saying because handing the word back instead is not obviously wrong — it is four
      # billion where the program says minus one, and a game's own test of it (`count > 0` is
      # false while the count is minus one) then passes while meaning the opposite. It also puts
      # this beside the interpreter's answer for the same variable, which is how anything lining
      # the two backends up compares them at all.
      #
      # {#mem32} is the other half and stays the raw word: an address is whatever is at it, and
      # a hardware register is not a whole number in a program.
      def var(name)
        unless @var_addresses
          refuse_missing_build_record!("where its variables are", or_else: "or hand the Verifier where they are: " \
                                                                         "`vars: backend.var_addresses`")
          raise ArgumentError,
                "no variable map given — build the Verifier with `vars: backend.var_addresses` to read a variable"
        end
        address = @var_addresses[name] ||
                  raise(ArgumentError, "unknown variable #{name.inspect} — known: #{@var_addresses.keys.join(', ')}")
        var_at(address)
      end

      # The variable at an address, with its sign put back — the rule above, kept in one place so
      # that anything reading a variable the program never named (the framework keeps a few of its
      # own) reads it the same way a game's own variable is read.
      def var_at(address) = IR::Int32.wrap(mem32(address))

      # THE COLOURS THE CONSOLE IS DRAWING FROM — the backgrounds' first and then the sprites',
      # each a 15-bit colour: 512 on an Advance, in groups of sixteen, and 64 on a Color, in
      # groups of four (see PaletteLayout).
      #
      # A game fades, tints, or recolours a character by changing these rather than by redrawing
      # anything, so "did the fade happen" or "is he wearing the hurt colours" asked of the
      # picture is a question about these numbers put the long way round, and one that whatever
      # else is on screen can confuse.
      #
      # NAME THE HALF AND THE GROUP to get a usable answer. An Advance sprite's row (see
      # {#sprites}) says which GROUP it draws from and nothing about where that group sits, so
      # `palette(:sprites, row.palette)` is the sixteen colours that row is wearing. Half on its
      # own (`palette(:sprites)`) is that half; nothing at all is the whole table.
      #
      # @param half [Symbol, nil] +:sprites+ or +:backgrounds+; nil for the whole table
      # @param group [Integer, nil] which group within that half
      # @return [Array<Integer>]
      def palette(half = nil, group = nil)
        ensure_rendered!
        whole = @probe.palette
        return whole if half.nil?

        layout = @reading::PALETTE
        from = layout.halves.fetch(half) do
          raise ArgumentError, "There is no #{half.inspect} half of the colour table. " \
                               "The halves are: #{layout.halves.keys.map(&:inspect).join(', ')}."
        end
        return whole[from, layout.half] if group.nil?

        groups = layout.half / layout.group
        unless group.is_a?(Integer) && group.between?(0, groups - 1)
          raise ArgumentError, "Each half of the colour table has #{groups} groups of #{layout.group}, " \
                               "numbered 0 to #{groups - 1}. #{group.inspect} is not one of them."
        end
        whole[from + (group * layout.group), layout.group]
      end

      # DRAW THE PICTURE WITHOUT SOME OF IT, so a test can ask which layer drew what.
      #
      #   v.showing(only: :sprites) { v.step; v.pixel_is?(44, 44, :red) }
      #
      # The console composes one picture out of four backgrounds and the sprites, and the finished
      # picture cannot be asked which of them drew a given pixel. So "is the hero there at all",
      # asked of a hero standing behind a fence, has no answer in it. Leave the rest out and the
      # question is just "what is left".
      #
      # NOTHING IS REDRAWN BY ASKING — this changes the console, not the reading — so the block
      # has to {#step} before it reads anything, or it reads the picture from before the layer
      # went. With a block the layers go back as they were afterwards, which is why the block form
      # is the one to reach for; without one the change stands for the rest of the run.
      #
      # +only:+ keeps the layers named and leaves out the rest; +without:+ leaves out the ones
      # named. Either takes one name or a list, from {#layers}.
      #
      # @return [Object] the block's value, or self when there is no block
      def showing(only: nil, without: nil)
        ensure_rendered!
        return @probe.showing(only: only, without: without) { yield self } if block_given?

        @probe.showing(only: only, without: without)
        self
      end

      # MIX THE SOUND WITHOUT SOME OF IT, so a test can ask which voice sounded.
      #
      #   v.hearing(only: :noise) { v.step(10); v.audio_energy_by_frame.last(10).sum }
      #
      # A game with music under its effects mixes down to one loudness, and that number cannot say
      # which voice put what into it — so "did the explosion sound" cannot be asked of it at all
      # while the music plays. Silence the rest and it can.
      #
      # Same words and the same warning as {#showing}: +only:+ keeps, +without:+ leaves out, a
      # block puts the voices back afterwards, and the block has to {#step} to hear anything. The
      # sound readers here cover the WHOLE run, so a block reads the frames it just played —
      # `audio_energy_by_frame.last(n)` — rather than the total.
      #
      # TAKING A VOICE OUT FROM UNDER A NOTE IT IS HOLDING IS A CUT, not a rest. The mix steps
      # down where that note was and drifts back over about half a second, so a reading taken
      # straight after is a reading of the cut and "has it gone quiet" wants half a second first.
      #
      # @return [Object] the block's value, or self when there is no block
      def hearing(only: nil, without: nil)
        ensure_rendered!
        return @probe.hearing(only: only, without: without) { yield self } if block_given?

        @probe.hearing(only: only, without: without)
        self
      end

      # The layers {#showing} can name — four backgrounds and the sprites.
      def layers
        ensure_rendered!
        @probe.layers
      end

      # The voices {#hearing} can name — two square voices, the wave voice, the noise voice, and
      # the two the recorded sound comes out of.
      def channels
        ensure_rendered!
        @probe.channels
      end

      # --- what each console's cartridge is asked its own way ---
      #
      # A READER IS GIVEN ITS CONSOLE'S QUESTIONS WHEN IT IS MADE, from the console's kit
      # (Console::Kit#reading). Every console's has +sprites+ and +passes+, each read the way that
      # console keeps them; an Advance cartridge's has the processor as well (+registers+,
      # +run_until+, +wave_rate+, +pad_reads+) and its mixer of recordings (+voices+, +sounding+,
      # +sample_clock+, +sound_drops+). A reader over a Color cartridge has none of those, so it is
      # never asked them. See AdvanceReading and ColorReading.
      #
      # +sprites+ ROWS ANSWER +name+, +x+ AND +y+ THE SAME ON EVERY CONSOLE: the sprite the game
      # declared, and where the game put the corner of its picture. What else a row carries is the
      # console's — an Advance cartridge's rows are SpriteRows, off its table of 128, and a Color
      # cartridge's are DrawnSprites, the list its runtime keeps of what it placed.
      #
      # +passes+ IS HOW MANY TIMES ROUND THE GAME LOOP THE CONSOLE GOT, in the frames it ran. This
      # is not the frame count, and the difference is the reason it exists: the console runs the
      # loop once per frame it has TIME for, so a game whose pass does not fit in a frame plays less
      # game per frame than one that does. Anything lining this run up against a run somewhere
      # else — the interpreter, an earlier build — has to line up on passes.

      # --- audio ---
      #
      # The counterpart to reading pixels: read the sound that actually came out.
      # The emulator mixes each frame to stereo PCM and we keep the whole run, so
      # these ask "what did the speaker do?" rather than trusting the ROM's bytes.
      #
      # THE WHOLE RUN, HOWEVER LONG. The sound of a long run is mostly in a scratch file and
      # not in memory (see RecordedSound). The energy readers go through each frame once and
      # keep its figure, so they can be asked after every frame of a long run: the only sound
      # an asking reads is the frames played since the last. #audio_samples is the one that
      # keeps nothing: it hands back every sample of the run at once, read from the file
      # each time, which for a long run is all of it in memory after all.

      # Total absolute amplitude across every PCM sample captured — 0 is perfect
      # silence. A deliberately crude "did any sound come out?" measure that doesn't
      # care about pitch or waveform, only whether the hardware made noise.
      def audio_energy = audio_energy_by_frame.sum

      # The sound itself: one Integer per 16-bit sample, the two channels interleaved.
      #
      # What this answers that #audio_energy cannot is what SHAPE the sound had. A break in the
      # stream — the mixer handing the hardware a buffer that does not line up with what it eats
      # — is a jump from one sample to the next, and a run full of them has exactly the same
      # total energy as a clean one.
      def audio_samples
        ensure_rendered!
        @sound.bytes.unpack("s<*")
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
      #
      # IT CAN BE ASKED AFTER EVERY FRAME. Each frame's figure is worked out once and kept
      # (see RecordedSound#energy_by_frame), so asking again reads the sound of the frames
      # played since and not of the run so far: `audio_energy_by_frame.last` after each step
      # is how loud that frame was.
      def audio_energy_by_frame
        ensure_rendered!
        @sound.energy_by_frame
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
        lines << "  Frames rendered: #{@played}"

        # Count unique colors
        colors = frame_gba.tally

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

      # A QUESTION ANOTHER CONSOLE'S CARTRIDGES ANSWER, asked of this one — the registers of a
      # Color game, say. This reader does not have the question (it does not answer respond_to?
      # for it), but a playthrough script written for one console and played on another is an
      # ordinary slip, so it is told in plain words which consoles have the question and what to
      # read instead, rather than handed Ruby's word that the method is undefined.
      def method_missing(question, *, **, &)
        answering = Console.kits.select { |kit| kit.reading.method_defined?(question) }.map(&:title)
        return super if answering.empty?

        raise NoMethodError.new("A #{Console.for(@rom.console).title} cartridge has no `#{question}`. Only a " \
                                "cartridge for the #{answering.join(' or the ')} has it. Read the cartridge's memory " \
                                "by address (`mem8`, `mem16`, `mem32`), its variables (`var`), its sprites " \
                                "(`sprites`) or its screen instead.", question)
      end

      # Only the questions this cartridge's console answers are this reader's (see #method_missing).
      def respond_to_missing?(_question, _include_private = false) = false

      # WHAT A CARTRIDGE WITH NO BUILD RECORD SAYS WHEN ASKED FOR WHAT ONLY THE BUILD KNEW:
      # which variable is where, which sprite is which, where a routine or a voice is. All
      # of that is worked out as a cartridge is built and kept beside it, never in it.
      #
      # There are two ways to have none, and they want different words. A cartridge that was
      # not built here — somebody else's, or one of this framework's once it is only a file
      # — never had one to give, which is a fact about the cartridge: it is told what can be
      # read instead. One assembled here from machine code, with the record left out, is a
      # slip in a test: it is told how to put the record in. +or_else+ is another way round
      # for that second case.
      def refuse_missing_build_record!(what, or_else: nil)
        return if @rom.built

        unless @rom.is_a?(Cartridge::ROM)
          raise ArgumentError, "This cartridge was not built here, so nothing says #{what}. A build works that out, and " \
                               "it is kept beside the cartridge and never in the file. Read the cartridge's memory by " \
                               "address (`mem8`, `mem16`, `mem32`) or its screen (`pixel_gba`, `frame_gba`) instead."
        end
        raise ArgumentError, "This cartridge was assembled without its build record, so nothing says #{what}. Assemble it " \
                             "with the record: `ROM.assemble(code, ..., built: backend.build_record(program))`" \
                             "#{", #{or_else}" if or_else}."
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
      # MADE WHEN THIS FILE LOADS rather than the first time a cartridge saves, which reads
      # as wasteful and is the only arrangement that works. Several cartridges can now be
      # verified at once, on different cores, and a core may not write anything kept by a
      # class — so whichever one got there first could not make this, and the run stopped.
      # Made before there are any cores, it is only ever read.
      #
      # An empty directory and one entry in the list of things to tidy up at exit is what
      # that costs somebody who only ever builds cartridges and never runs one.
      #
      # TAKEN AWAY AFTER EVERY at_exit HOOK, not by one. A test suite commonly runs its tests
      # FROM an at_exit hook — minitest does — and Ruby runs those hooks newest first, so a
      # hook registered here, after the test runner's, ran before a single test and took the
      # directory away. The emulator quietly made it again the first time it opened a
      # cartridge, which hid this until a test wanted to put a save in it beforehand. What
      # Ruby does after the last at_exit hook is finish the objects still alive, so the
      # directory goes when this constant's keeper is finished.
      SAVE_DIR = Dir.mktmpdir("verify-save").freeze
      SAVE_DIR_KEEPER = Object.new.tap do |keeper|
        ObjectSpace.define_finalizer(keeper, ->(_) { FileUtils.remove_entry(SAVE_DIR, true) })
      end.freeze

      def self.save_dir = SAVE_DIR

      # Fill the chip before the console is turned on. The emulator looks for it as a file
      # named after the ROM, in the save directory, and reads it in as the chip's contents.
      # The file is as big as the cartridge's chip: a save memory made without a size takes the
      # cartridge's, and one of another size is refused, as the interpreter refuses it.
      def write_save_memory
        program = @rom.source_program
        @save.use_memory!(IR::SaveLayout.memory_of(program)) if program
        File.binwrite(save_path, @save.to_sav)
      end

      def save_path = File.join(self.class.save_dir, "#{File.basename(@tempfile.path, '.gba')}.sav")

      # The picture to compare this reader's with: another reader's, or one that was kept.
      #
      # Anything else is refused here, by size: a picture is four bytes a pixel, and the one
      # thing most easily handed over in its place is {#frame_colors}, which is two.
      def picture_of(other)
        return other.picture if other.respond_to?(:picture)
        return other if other.is_a?(String) && other.bytesize == picture.bytesize

        given = other.is_a?(String) ? "a string of #{other.bytesize} bytes" : "an object of class #{other.class}"
        raise ArgumentError,
              "A picture can be compared with another running cartridge, or with a picture kept from " \
              "one. This was #{given}, and a picture here is #{picture.bytesize} bytes. Give another " \
              "reader, or what `picture` handed back earlier. `frame_colors` and `frame_gba` are the " \
              "colours of a picture, and are not one."
      end

      def ensure_rendered!
        return if @rendered

        # Write ROM to a temp file, open the emulator on it, and play the frames the run was
        # built with.
        #
        # Keep the emulator (and its ROM file) alive on the instance rather than tearing them
        # down here: memory reads (#mem32 / #var) run against the same console after the frames,
        # at the final frame boundary. Both are released when this Verifier is garbage-collected.
        @tempfile = Tempfile.new(["verify", ".gba"])
        @tempfile.binmode
        @rom.write(@tempfile.path)
        @tempfile.flush
        write_save_memory if @save
        @probe = Emulator.probe(@tempfile.path, save_dir: self.class.save_dir)
        # The picture is the size the console draws, which the emulator knows from the cartridge.
        @width = @probe.width
        @height = @probe.height
        @probe.clock_at(@clock, set: @clock_set) if @clock
        @rendered = true
        watch_passes! # the console's own; before any frame runs, or the first passes go uncounted
        play(@frames)
      end

      # PLAY +count+ FRAMES and keep what they produced: the picture the last of them left, and
      # the sound each one made, kept frame by frame so a run can be asked whether the sound
      # arrived evenly rather than only how much of it there was.
      #
      # The frames go over in one go when the same buttons are held throughout, which is the
      # usual case and which reads the picture once rather than once per frame. Input that
      # changes frame by frame has to be handed over a frame at a time, so it is.
      #
      # A LONG RUN OF FRAMES IS PLAYED IN SEVERAL STEPS, none longer than the frames of sound
      # this reader holds in memory. The emulator holds the sound of a step until the step
      # ends, so an hour played as one step would be an hour of sound in memory on its way to
      # a reader that was built not to hold it.
      def play(count, holding: nil)
        return unless count.positive?

        changing = (holding || @keys).respond_to?(:call)
        (changing ? Array.new(count, 1) : frames_in_steps(count)).each do |frames|
          @probe.step(frames, keys: keys_for(@played, holding: holding))
          @sound.keep(@probe.audio_by_frame)
          @played += frames
        end
        # Kept so that it cannot be changed: it is handed out as `picture`, and the emulator's
        # own reader holds the same string.
        @pixels = @probe.frame_buffer.freeze
      end

      # +count+ frames as the steps they are played in, none longer than the sound kept in memory.
      def frames_in_steps(count)
        whole, rest = count.divmod(@sound.frames_in_memory)
        Array.new(whole, @sound.frames_in_memory) + (rest.zero? ? [] : [rest])
      end

      def refuse_sound_not_recorded_sound!(given)
        return if given.is_a?(RecordedSound)

        raise ArgumentError, "`sound:` was #{given.inspect}. It must be a RecordedSound, which says how many frames " \
                             "of sound the reader holds in memory: " \
                             "`sound: VBlank::Diagnostics::RecordedSound.new(frames_in_memory: 600)`."
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
        Graphics::Color::PRESETS.each do |name, val|
          return "(#{name})" if val == gba_color
        end
        ""
      end
    end
  end
end
