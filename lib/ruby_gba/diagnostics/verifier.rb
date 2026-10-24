# frozen_string_literal: true

# REQUIRED HERE AND NOT WHERE THEY ARE USED, which is the opposite of the usual advice about
# a cost you may not pay. Asking for a file reads the list of places Ruby looks for one, and
# that list is a global — which a worker may not read at all. So a `require` reached while a
# cartridge is being verified stops the run, and these are on that path: a verified ROM goes
# through a temporary file every time.
require "tempfile"
require "tmpdir"
require "fileutils"

module RubyGBA
  module Diagnostics
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
    #   v = RubyGBA::Diagnostics::Verifier.new(rom)
    #   v.pixel(120, 80)        # => { r: 248, g: 0, b: 0 }
    #   v.pixel_gba(120, 80)    # => 0x001F (15-bit GBA color)
    #   v.red?(120, 80)         # => true
    #   v.black?(0, 0)          # => true (no pixel drawn there)
    #
    # @example Check a region
    #   v.all_black?                        # => false (we drew a pixel)
    #   v.region_color?(80, 50, 80, 60, :blue)  # all blue in rect?
    class Verifier
      include Console::Hardware

      # @param rom [RubyGBA::Cartridge::ROM] a finalized ROM
      # @param frames [Integer] how many frames to run before reading pixels (default: 2)
      # @param keys [Integer, #call, nil] held-button input for each frame — an
      #   active-high bitmask (bit per button, matching KEY_*), or a callable given
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
        @passes_counted = false
        @rendered = false
        @played = 0
        @pixels = nil
        @sound = sound
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
      # @return [Array<Integer>] 240*160 colors in BGR555
      def frame_gba = Emulator.screen_questions.color_list(picture)

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
      def save_image
        bytes = save_bytes
        bytes && IR::SaveImage.from_sav(bytes, from: "The bytes of this cartridge's save memory")
      end

      # The save chip as it is now, as the bytes of the file the emulator keeps it in, or nil
      # for a cartridge with no save chip. This is every chip there is, whatever its size;
      # {#save_image} is the same bytes as a chip the framework has a model of.
      def save_bytes
        ensure_rendered!
        File.binread(save_path) if File.size?(save_path)
      end

      # How many times the game read the pad while the console ran it — what the emulator saw,
      # which is not the same as how many passes a game loop made (see Probe#pad_reads).
      #
      # @return [Integer]
      def pad_reads
        ensure_rendered!
        @probe.pad_reads
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

      # THE SPRITES THE CONSOLE IS DRAWING, each knowing which one the game declared it for.
      #
      # One Hash per sprite being drawn, off the console's own table — +:name+, +:x+, +:y+,
      # +:slot+, +:tile+, +:palette+, +:color_count+, +:colors+, +:priority+, +:shape+, +:size+,
      # +:mirrored_across+, +:mirrored_down+, +:turned+, +:piece_x+, +:piece_y+. Name one and only
      # that sprite's rows come back.
      #
      # +:colors+ IS THE COLOURS IT IS WEARING, ready to compare against — no group number and no
      # arithmetic, and right for a picture stored either of the two ways (see #colors_drawn_from,
      # and +:color_count+, which says which way).
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
        rows = named_sprite_rows
        return rows if name.nil?

        known = sprite_slots!
        unless known.key?(name)
          raise ArgumentError, "This game has no sprite #{name.inspect}. " \
                               "Its sprites are: #{known.keys.map(&:inspect).join(', ')}."
        end
        rows.select { |row| row.name == name }
      end

      # THE COLOURS THE CONSOLE IS DRAWING FROM — 512 of them, the backgrounds' first and then
      # the sprites', each a 15-bit colour.
      #
      # A game fades, tints, or recolours a character by changing these rather than by redrawing
      # anything, so "did the fade happen" or "is he wearing the hurt colours" asked of the
      # picture is a question about these numbers put the long way round, and one that whatever
      # else is on screen can confuse.
      #
      # NAME THE HALF AND THE GROUP to get a usable answer. A sprite's row (see {#sprites}) says
      # which GROUP OF SIXTEEN it draws from and nothing about where that group sits, so
      # `palette(:sprites, row.palette)` is the sixteen colours that row is wearing. Half on its
      # own (`palette(:sprites)`) is that half's 256; nothing at all is the whole table.
      #
      # @param half [Symbol, nil] +:sprites+ or +:backgrounds+; nil for the whole table
      # @param group [Integer, nil] which group of sixteen within that half
      # @return [Array<Integer>]
      def palette(half = nil, group = nil)
        ensure_rendered!
        whole = @probe.palette
        return whole if half.nil?

        from = PALETTE_HALVES.fetch(half) do
          raise ArgumentError, "There is no #{half.inspect} half of the colour table. " \
                               "The halves are: #{PALETTE_HALVES.keys.map(&:inspect).join(', ')}."
        end
        return whole[from, PALETTE_HALF] if group.nil?

        whole[from + (group * PALETTE_GROUP), PALETTE_GROUP]
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

      # The pitch the wave voice is playing at, as the rate a game writes for it. Ask this rather
      # than reading the register back: the console makes those bits write-only, so {#mem16}
      # there says 0 whatever note is playing. See Probe#wave_rate.
      def wave_rate
        ensure_rendered!
        @probe.wave_rate
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

        [@probe.arrivals - @pass_in_flight, 0].max
      end

      # --- the processor ---
      #
      # For debugging what the lowering emitted: stop the running cartridge at the first
      # instruction of a routine, then read what the processor holds there. The frames run
      # first, so the stop is the next time the routine is reached after them.

      # How many instructions {#run_until} runs before it gives up: several frames of a game
      # that never sleeps.
      RUN_UNTIL_LIMIT = 2_000_000

      # HOW THE CONSOLE'S 512 COLOURS ARE LAID OUT: the backgrounds' 256 first, then the
      # sprites'. Each half is sixteen groups of sixteen, and a sprite is told which group it
      # draws from — so these are what turns "group 4" into a place in the table.
      PALETTE_HALF = 256
      PALETTE_GROUP = 16
      PALETTE_HALVES = { backgrounds: 0, sprites: PALETTE_HALF }.freeze

      # Run on until the routine named +routine+ is about to run its first instruction. The
      # name is the one the program gave it (`func(:count_up)`), or BuildRecord::FRAME_ROUTINE
      # for the game loop's own body. Raises when the routine is never reached, rather than
      # leaving the processor somewhere else to be read as if it were there.
      def run_until(routine, limit: RUN_UNTIL_LIMIT)
        ensure_rendered!
        address = routine_start!(routine)
        @probe.run_until(address, limit: limit)
        self
      rescue RuntimeError
        # The emulator says which ADDRESS it failed to reach, which is the only thing it knows.
        # Only the build can turn that back into the name the program gave the routine, and the
        # name is the whole reason anybody asked for it here.
        raise RuntimeError, format("The routine %p (at 0x%08X) did not run within %d instructions.",
                                   routine, address, limit)
      end

      # What the processor holds right now: +:r0+ through +:r14+, +:pc+ (the instruction that
      # runs next) and +:cpsr+.
      def registers
        ensure_rendered!
        @probe.registers
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
        table = sound_drop_counters!
        table ? table.read { |address| mem32(address) } : SoundDrops::Reading.unmeasured
      end

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

      # The cartridge's record of where it keeps its voices, or nil for a program that plays no
      # samples. A cartridge with no build record cannot answer.
      def voice_table!
        refuse_missing_build_record!("where it keeps its voices")
        @rom.built.voices
      end

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

      # Every row of the console's table, each with the name of the sprite the game declared it
      # for. Read once per call, so a test that steps the cartridge on sees where things moved to.
      def named_sprite_rows
        ensure_rendered!
        whose = sprite_slots!.each_with_object({}) do |(name, slots), by_slot|
          slots.each { |slot| by_slot[slot] = name }
        end
        moved = @rom.built.sprite_offsets
        rooms = @rom.built.streamed_sprite_pose_vars
        # A run drawn in an order the game works out moves its sprites' rows about, so a row is
        # taken back to the sprite's own place before anything is looked up by place.
        own = (@rom.built.sprite_runs || []).reduce({}) { |found, run| found.merge(run.own_places(method(:mem8))) }
        table = palette(:sprites) # read once for the lot, not once per row
        turns = @rom.built.sprite_turns || {}
        @probe.sprites.map do |row|
          home = own.fetch(row[:slot], row[:slot])
          name = whose[home]
          dx, dy = moved.dig(home, pose_key(row, rooms, home)) || [0, 0]
          # A place several scenes' sprites take turns at is the sprite of the scene the table
          # was last written for.
          if (turn = turns.fetch(home, []).find { |each_turn| var_at(each_turn.at) == each_turn.value })
            name = turn.name
            dx, dy = turn.offsets[turn_pose_key(row, turn)] || [0, 0]
          end
          # Back into the ranges the console keeps these in, so a sprite half off the left edge
          # reads the way its own place reads rather than going negative.
          SpriteRow.new(**row, name: name, piece_x: row[:x], piece_y: row[:y],
                        x: (row[:x] - dx) & 0x1FF, y: (row[:y] - dy) & 0xFF,
                        colors: colors_drawn_from(row, table))
        end
      end

      # THE COLOURS A ROW IS DRAWING FROM, which is the question the row's +palette+ field looks
      # like an answer to and is not.
      #
      # A picture is stored one of two ways, and the console picks by how many colours the art
      # uses: half a byte a pixel, picking out of a GROUP of sixteen colours, or a whole byte
      # picking out of all 256. +palette+ names the group, so it is the answer for the first kind
      # and means nothing for the second — and the two look identical from outside, which is why
      # handing over "the sixteen at that group" would be quietly wrong for a sprite drawn from
      # more than fifteen colours rather than obviously wrong.
      #
      # +color_count+ says which kind, so this can simply take the right run: the group for a
      # picture that has one, and the whole table for a picture that draws from all of it.
      def colors_drawn_from(row, table)
        from = row[:color_count] == PALETTE_GROUP ? row[:palette] * PALETTE_GROUP : 0
        table[from, row[:color_count]]
      end

      # WHICH POSE A ROW IS HOLDING, said the way the build wrote that place's trims down (see
      # IR::Backends::GBA#pose_key, the other end of this).
      #
      # Nearly every sprite keeps all its pictures in sprite memory at once, and then the row tells
      # its own poses apart: the tiles it draws and whether it is drawn backwards differ for every
      # pose, so those two are the answer.
      #
      # A sprite with more pictures than fit keeps ONE of them there at a time, and then the row
      # cannot: every pose is copied into the same room, so it says that one place whichever pose
      # is in it. The cartridge keeps the pose number in a variable of its own for exactly that
      # reason — it is how it knows whether the frame already in the room is still the right one —
      # and the build says where, so this reads it rather than guessing from a row that cannot
      # know. A room nothing has been copied into yet holds no pose at all, and no pose finds no
      # trim; a row being drawn always has one, because the frame goes in before the row is
      # written.
      def pose_key(row, rooms, home = row[:slot])
        address = rooms[home] or return [row[:tile], row[:mirrored_across], row[:mirrored_down]]

        var_at(address)
      end

      # ...the same, for a sprite taking its turn at a place (see BuildRecord#sprite_turns),
      # which says itself where its pose is kept when it keeps one frame at a time.
      def turn_pose_key(row, turn)
        return [row[:tile], row[:mirrored_across], row[:mirrored_down]] if turn.pose_var.nil?

        var_at(turn.pose_var)
      end

      # Which places the build gave each declared sprite. A cartridge with no build record
      # cannot say.
      def sprite_slots!
        refuse_missing_build_record!("which of its sprites is which")
        @rom.built.sprite_slots
      end

      # Where a routine's first instruction really is while the cartridge runs — which is not
      # where it sits in the cartridge when it was copied into the console's quick memory, so
      # only the build record can say.
      def routine_start!(routine)
        refuse_missing_build_record!("where its routines are")
        span = @rom.built.routines[routine] or
          raise ArgumentError, "This ROM has no routine #{routine.inspect}. " \
                               "Its routines are: #{@rom.built.routines.keys.map(&:inspect).join(', ')}."
        span.begin
      end

      # ...and where it counts what it could not play. Same rule: only the build knows, because
      # the counters are hidden variables.
      def sound_drop_counters!
        refuse_missing_build_record!("where it counts the sounds it dropped")
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
        @probe.clock_at(@clock, set: @clock_set) if @clock
        @rendered = true
        watch_game_loop_passes! if @count_passes
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
                             "`sound: RubyGBA::Diagnostics::RecordedSound.new(frames_in_memory: 600)`."
      end

      # Watch for arrivals at the game loop's first instruction, before any frame runs. A
      # program with no game loop has no such routine, and that is an answer rather than an
      # error — see {#passes}.
      def watch_game_loop_passes!
        refuse_missing_build_record!("where its game loop is, so its passes cannot be counted")
        span = @rom.built.routines[Cartridge::BuildRecord::FRAME_ROUTINE]
        return unless span

        # The start of the pass, or the end of it — see {#passes} for why each shape gets the
        # one it does, and what each means for the pass that is still running when we stop.
        kept_fast = @rom.built.frame_in_quick_memory?
        @pass_in_flight = kept_fast ? 1 : 0
        @probe.watch_arrivals(kept_fast ? span.begin : span.end)
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
        Graphics::Color::PRESETS.each do |name, val|
          return "(#{name})" if val == gba_color
        end
        ""
      end
    end
  end
end
