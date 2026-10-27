# frozen_string_literal: true

module VBlank
  module Live
    # A WINDOW TO PLAY A GAME IN: the device Session shows a game on when a person is playing it.
    # The window, the keyboard and the clock are SDL3's, a C library every desktop has a build of,
    # reached through Fiddle, Ruby's own way of calling a C library: no C of this library's to
    # compile.
    #
    # The picture goes into the window as it is. The console keeps a color in fifteen bits, five
    # each of red, green and blue with red lowest, and SDL takes exactly that (its XBGR1555
    # format), so a picture is packed two bytes a pixel and handed over, then scaled up with each
    # pixel kept square and sharp. The window can be made any size; the picture keeps its shape,
    # with bars where the window is the wrong shape for it.
    #
    # The keys, as mGBA and the desktop build have them: the arrows are the pad, X is A, Z is B,
    # Enter is Start, Backspace is Select, A and S are the shoulder buttons L and R. A gamepad
    # plugged in plays too (PAD_BUTTONS). As in the desktop build, P pauses and carries on, Tab
    # held fast forwards, and F1 opens the menu (Menu, WindowMenu), which holds the
    # game while it is open; so does the key above Tab, and on a gamepad the guide button, or Back
    # and Start together. Escape, or closing the window, stops the play.
    #
    # THE MENU is drawn over the picture in the window's own pixels, not the game's: the picture is
    # the console's few pixels made big and square, and the menu over it is as sharp as the screen
    # can show, a Retina screen's two pixels a point included (the window asks SDL for them). Menu
    # says where each box and word goes; the boxes are drawn here as triangles with their edges
    # faded over a pixel, as Dear ImGui draws them, and each letter is copied out of the menu
    # font's picture (Graphics::MenuFont), which is put on the screen's card when the window
    # opens.
    #
    # THE SOUND goes to the computer's speaker through an SDL audio stream, a queue the speaker
    # plays from at its own steady rate while the game puts a frame's samples in at the end of
    # each pass. The window says how much is waiting (#sound_waiting), and the session paces the
    # play by it, so the game keeps the speaker's time and the queue holds steady at a few frames:
    # one clock, the speaker's, and nothing to drift. A game far ahead of the speaker — played
    # uncapped — has the frames past a few thrown away. A computer with no sound plays the game
    # silent, on the session's clock.
    class SDL
      # SDL3 or Fiddle could not be found, said in plain words with what to install.
      class Missing < StandardError; end

      # SDL could not do something it was asked, said with SDL's own words.
      class Failed < StandardError; end


      # Where SDL3 is looked for when neither +library:+ nor VBLANK_SDL3 names it: the names each
      # system's loader finds by itself, then the folders Homebrew installs into on a Mac.
      LIBRARIES = Ractor.make_shareable(%w[libSDL3.dylib libSDL3.0.dylib libSDL3.so.0 libSDL3.so SDL3.dll
                                           /opt/homebrew/lib/libSDL3.dylib /usr/local/lib/libSDL3.dylib])

      INSTALL_LINE = "On macOS, run `brew install sdl3`. On Debian or Ubuntu, run `apt install libsdl3-dev`."

      # SDL's own numbers, from its headers.
      INIT_VIDEO = 0x20
      WINDOW_RESIZABLE = 0x20
      WINDOW_HIGH_PIXEL_DENSITY = 0x2000 # a Retina screen's own pixels, not one a point
      PIXELFORMAT_XBGR1555 = 0x15530f02
      PIXELFORMAT_ABGR8888 = 0x16762004 # red, green, blue, opacity: a byte each, in that order
      TEXTUREACCESS_STATIC = 0
      TEXTUREACCESS_STREAMING = 1
      SCALEMODE_NEAREST = 0
      SCALEMODE_LINEAR = 1
      LOGICAL_PRESENTATION_DISABLED = 0
      LOGICAL_PRESENTATION_LETTERBOX = 2
      EVENT_QUIT = 0x100
      EVENT_WINDOW_CLOSE_REQUESTED = 0x210
      EVENT_KEY_DOWN = 0x300
      EVENT_KEY_UP = 0x301
      KEY_SCANCODE_AT = 24 # where in a key's event the key is, as a scancode (4 bytes)
      KEY_DOWN_AT = 36 # ...whether it went down (1 byte)
      KEY_REPEAT_AT = 37 # ...and whether it is a key held down, heard again (1 byte)
      EVENT_BYTES = 128 # an SDL_Event is a union of at most this many bytes
      BLENDMODE_BLEND = 0x1 # what is drawn lets what is under it show through, as much as it is clear
      WINDOW_FLAGS_FULLSCREEN = 0x1
      INIT_AUDIO = 0x10
      AUDIO_S16 = 0x8010 # 16-bit samples, the low byte first
      SAMPLE_BYTES = 2 # ...so two bytes each
      AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF

      # The most frames' worth of sound kept waiting before a frame is thrown away. Played live, the
      # speaker paces the play and keeps a few frames waiting (Session::SPEAKER_AHEAD_FRAMES), so
      # the queue grows past this only uncapped. Where the speaker runs out — a machine too slow for
      # the game — SDL plays silence until the next frame's sound comes, and nothing here adds any:
      # the speaker may still be playing what it took last, and silence put in then is a gap.
      SOUND_BEHIND_FRAMES = 6

      # The console's buttons, by the key that holds each (SDL's scancodes, which name a place on
      # the keyboard rather than a letter, so the layout of the keyboard does not move them).
      KEYS = Ractor.make_shareable({ right: 79, left: 80, down: 81, up: 82, a: 27, b: 29, start: 40, select: 42,
                                     l: 4, r: 22 })
      ESCAPE = 41
      PAUSE = 19 # P, the desktop build's pause key too
      FAST_FORWARD = 43 # Tab, held, as in the desktop build and many an emulator
      MENU = 58 # F1, the desktop build's menu key too
      # The keys the menu names (WindowMenu), by scancode.
      KEY_CODES = Ractor.make_shareable({ f1: MENU, grave: 53, up: 82, down: 81, left: 80, right: 79, enter: 40 })
      MENU_OPENERS = Ractor.make_shareable(WindowMenu::OPEN_KEYS.map { |name| KEY_CODES.fetch(name) })

      # A GAMEPAD'S BUTTONS, by SDL's numbers for them, and the console's button each is: the
      # console's own layout, as the desktop build sets it to begin with — A on the right (SDL's
      # "east"), B below it ("south"), the back and start buttons, the shoulders, the D-pad.
      PAD_SOUTH = 0 # SDL's numbers for a gamepad's buttons, from its headers
      PAD_EAST = 1
      PAD_BACK = 4
      PAD_START = 6
      PAD_LEFT_SHOULDER = 9
      PAD_RIGHT_SHOULDER = 10
      PAD_DPAD_UP = 11
      PAD_DPAD_DOWN = 12
      PAD_DPAD_LEFT = 13
      PAD_DPAD_RIGHT = 14
      PAD_BUTTONS = Ractor.make_shareable({ PAD_EAST => :a, PAD_SOUTH => :b, PAD_BACK => :select, PAD_START => :start,
                                            PAD_DPAD_RIGHT => :right, PAD_DPAD_LEFT => :left, PAD_DPAD_UP => :up,
                                            PAD_DPAD_DOWN => :down, PAD_RIGHT_SHOULDER => :r, PAD_LEFT_SHOULDER => :l })
      PAD_LEFT_X = 0 # SDL's numbers for the left stick's two ways
      PAD_LEFT_Y = 1
      # How far the stick goes each way is a number up to 32767. A stick at rest seldom reads
      # nought, so it moves the game only once pushed past this, about a third of the way.
      STICK_DEAD_ZONE = 10_000
      INIT_GAMEPAD = 0x2000
      EVENT_PAD_BUTTON_DOWN = 0x651 # (0x650 is a stick moving)
      EVENT_PAD_BUTTON_UP = 0x652
      EVENT_GAMEPAD_ADDED = 0x653
      EVENT_GAMEPAD_REMOVED = 0x654
      PAD_ID_AT = 16 # where in a pad's event its number is (4 bytes)
      PAD_BUTTON_AT = 20 # ...and in a button's event, which button (1 byte)
      # The gamepad buttons the menu names (WindowMenu), by SDL's number: A and B are
      # the console's, east and south, as PAD_BUTTONS has them.
      PAD_CODES = Ractor.make_shareable({ guide: 5, back: PAD_BACK, start: PAD_START, dpad_up: PAD_DPAD_UP,
                                          dpad_down: PAD_DPAD_DOWN, dpad_left: PAD_DPAD_LEFT,
                                          dpad_right: PAD_DPAD_RIGHT, a: PAD_EAST, b: PAD_SOUTH })
      PAD_MENU_KEYS = Ractor.make_shareable(WindowMenu::MOVE_PAD.to_h do |name, key|
        [PAD_CODES.fetch(name), key]
      end)
      PAD_OPENERS = Ractor.make_shareable(WindowMenu::OPEN_PAD.map { |name| PAD_CODES.fetch(name) })
      PAD_OPENERS_TOGETHER = Ractor.make_shareable(WindowMenu::OPEN_PAD_TOGETHER.map do |name|
        PAD_CODES.fetch(name)
      end)

      # The console's buttons a gamepad holds: +down+, SDL's numbers for the buttons down on it, and
      # the left stick's two ways, up being below nought.
      def self.pad_buttons(down:, stick_x:, stick_y:)
        held = down.filter_map { |button| PAD_BUTTONS[button] }
        held << :right if stick_x > STICK_DEAD_ZONE
        held << :left if stick_x < -STICK_DEAD_ZONE
        held << :down if stick_y > STICK_DEAD_ZONE
        held << :up if stick_y < -STICK_DEAD_ZONE
        held.uniq
      end

      # The keys the menu is worked with while it is open, by scancode: the arrows, and Enter.
      MENU_KEYS = Ractor.make_shareable(WindowMenu::MOVE_KEYS.to_h do |name, key|
        [KEY_CODES.fetch(name), key]
      end)

      # Whether SDL3 can be found and loaded here, without opening anything.
      def self.available?(library: nil)
        binding_for(library)
        true
      rescue Missing
        false
      end

      # A window +scale+ times a +width+ by +height+ picture, titled +title+. +library+ names the
      # SDL3 file to load, in place of looking for it. +menu+ false is a window F1 opens no menu
      # in, for a game that says it has none. A window that cannot be opened all the way is closed
      # again before the error comes out.
      def initialize(title:, scale: 3, width: 240, height: 160, library: nil, menu: true)
        @sdl = self.class.binding_for(library)
        @width = width
        @height = height
        @closed = false
        @has_menu = menu
        @kept_from_game = [] # keys pressed for the menu, kept from the game until they come up
        @pads = {} # the gamepads plugged in, by SDL's number for each
        @pad_down = Hash.new { |downs, id| downs[id] = [] } # the buttons down on each, as SDL said
        @pad_kept = [] # gamepad buttons pressed for the menu, kept from the game until they come up
        @shown_this_second = 0
        @second_began = now
        @frame_rate = 0 # pictures shown in the last whole second
        begin
          open_window(title, scale)
        rescue Failed
          close
          raise
        end
        @menu = Menu.new(settings: WindowMenu::STARTING.with(scale: scale), picture: [width, height],
                         scales: WindowMenu::SCALES.min..[largest_scale_that_fits, scale].max)
        @settings = @menu.settings # as the window last made them so
      end

      # The picture into the window, and whatever SDL has heard from the window since. The
      # picture is the size the window was opened for.
      def show(pixels, width, height)
        unless [width, height] == [@width, @height] && pixels.length == width * height
          raise ArgumentError, "The window shows a #{@width}x#{@height} picture, and it was given a " \
                               "#{width}x#{height} picture of #{pixels.length} pixels."
        end

        read_events
        count_frame_rate
        @sdl.SDL_UpdateTexture(@texture, nil, pixels.pack("v*"), @width * 2)
        redraw_window
      end

      # The console's buttons whose keys are down now, as SDL last heard them (#show reads what
      # SDL has heard). The keyboard is read when it is asked, whichever pass it is asked for. A
      # key pressed for the menu is not the game's until it comes up: Enter on Resume is not Start.
      #
      # Every gamepad plugged in holds buttons too, alongside the keyboard (SDL.pad_buttons), and
      # a gamepad button pressed for the menu is kept from the game the same way.
      def held_buttons(_pass)
        keys = @sdl.SDL_GetKeyboardState(nil)
        from_keys = KEYS.filter_map { |button, code| button if keys[code] != 0 && !@kept_from_game.include?(code) }
        (from_keys + @pads.values.flat_map { |pad| pad_held(pad) }).uniq
      end

      # A frame's sound, +samples+ 16-bit numbers at +rate+ a second, into the speaker's queue. The
      # speaker is opened the first time, at that rate.
      def play_sound(samples, rate)
        speaker = open_speaker_once(rate) or return
        return if samples.empty?

        bytes = samples.length * SAMPLE_BYTES
        return if @sdl.SDL_GetAudioStreamQueued(speaker) > SOUND_BEHIND_FRAMES * bytes

        @sdl.SDL_PutAudioStreamData(speaker, samples.pack("s<*"), bytes)
      end

      # Seconds of sound waiting for the speaker, or nil before the first frame's sound opens one,
      # or where it cannot be opened.
      def sound_waiting
        return nil unless live?(@speaker)

        @sdl.SDL_GetAudioStreamQueued(@speaker) / SAMPLE_BYTES / @speaker_rate.to_f
      end

      # The window was closed, or Escape is down, as SDL last heard it (#show reads what SDL has
      # heard, and Session shows each picture before it asks).
      def stop? = @closed || @sdl.SDL_GetKeyboardState(nil)[ESCAPE] != 0

      # The speed the menu says while Tab is held, as SDL last heard it (#show reads what SDL has
      # heard), and 1 while it is not, whichever pass it is asked for.
      def fast_forward_speed(_pass) = @fast_forward ? @settings.fast_forward_speed : 1

      # P was pressed, or F1 opened the menu (#show reads what SDL has heard): the window holds, the
      # picture up and the speaker emptied and silent, until P is pressed again, the menu is closed,
      # or the play is stopped. It waits on SDL for the next thing to happen to the window, so a
      # pause takes no time from the computer, and draws the picture again after each, so a window
      # resized while paused is not left blank. Says whether it held.
      def hold_while_paused
        return false unless held?

        empty_speaker
        while held? && !stop?
          read_event if @sdl.SDL_WaitEvent(@event) != 0
          redraw_window
        end
        resume_speaker
        true
      end

      # The window's size on the screen, in the computer's pixels, as SDL says it is.
      def window_size
        size = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        @sdl.SDL_GetWindowSize(@window, size, size + 4)
        size[0, 8].unpack("l2")
      end

      # How loud the speaker plays, from 0 (silent) to 1 (as loud as the game made it), as SDL
      # says; nil before the first frame's sound opens it.
      def speaker_volume = (@sdl.SDL_GetAudioStreamGain(@speaker) if live?(@speaker))

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def wait_until(seconds)
        ahead = seconds - now
        sleep(ahead) if ahead.positive?
      end

      # The window goes, and SDL with it. Closing twice does nothing more.
      def close
        @pads.each_value { |pad| @sdl.SDL_CloseGamepad(pad) }
        @pads = {}
        @sdl.SDL_DestroyAudioStream(@speaker) if live?(@speaker)
        @speaker = nil
        @sdl.SDL_DestroyTexture(@letters) if live?(@letters)
        @sdl.SDL_DestroyTexture(@texture) if live?(@texture)
        @sdl.SDL_DestroyRenderer(@renderer) if live?(@renderer)
        @sdl.SDL_DestroyWindow(@window) if live?(@window)
        @letters = @texture = @renderer = @window = nil
        @sdl.SDL_Quit
      end

      # THE BINDING: SDL3's functions as Ruby methods, made the first time a window is asked for
      # and kept for each library file, one set for each Ractor (Fiddle's handles are its own).
      def self.binding_for(library)
        require_fiddle!
        named = library || ENV.fetch("VBLANK_SDL3", nil)
        bindings = Ractor.current[:vblank_sdl_bindings] ||= {}
        return bindings[named || :found] if bindings.key?(named || :found)

        path = named ? (named if loadable?(named)) : LIBRARIES.find { |name| loadable?(name) }
        raise Missing, missing_message(named, library) unless path

        bindings[named || :found] = bind(path)
      end

      def self.require_fiddle!
        require "fiddle"
        require "fiddle/import"
      rescue LoadError
        raise Missing, "VBlank cannot open a window, because Ruby cannot load the gem `fiddle`. Ruby includes " \
                       "`fiddle`, but Bundler loads only the gems that the Gemfile names. If you use Bundler, " \
                       "add `gem \"fiddle\"` to your Gemfile and run `bundle install`. If you do not use Bundler, " \
                       "run `gem install fiddle`."
      end

      def self.loadable?(name)
        Fiddle.dlopen(name).close
        true
      rescue Fiddle::DLError
        false
      end

      def self.missing_message(named, library)
        if named
          said = library ? "the library: given to VBlank::Live::SDL" : "VBLANK_SDL3"
          return "VBlank cannot open SDL3 at #{named}. VBlank uses SDL3 to open a window. Make sure that " \
                 "#{said} names the SDL3 library file. #{INSTALL_LINE}"
        end
        "VBlank cannot find SDL3. VBlank uses SDL3 to open a window. It looked in: #{LIBRARIES.join(', ')}. " \
          "#{INSTALL_LINE} If SDL3 is in a different folder, set VBLANK_SDL3 to the path of the library file."
      end

      # SDL3 answers yes or no as a C bool, one byte, which Fiddle reads as a char.
      def self.bind(path)
        Module.new do
          extend Fiddle::Importer
          dlload path
          extern "char SDL_Init(unsigned int)"
          extern "void SDL_Quit()"
          extern "const char* SDL_GetError()"
          extern "void* SDL_CreateWindow(const char*, int, int, unsigned long long)"
          extern "void SDL_DestroyWindow(void*)"
          extern "char SDL_SetWindowSize(void*, int, int)"
          extern "char SDL_GetWindowSize(void*, void*, void*)"
          extern "char SDL_SetWindowFullscreen(void*, char)"
          extern "void* SDL_CreateRenderer(void*, const char*)"
          extern "void SDL_DestroyRenderer(void*)"
          extern "char SDL_SetRenderLogicalPresentation(void*, int, int, int)"
          extern "void* SDL_CreateTexture(void*, unsigned int, int, int, int)"
          extern "void SDL_DestroyTexture(void*)"
          extern "char SDL_SetTextureScaleMode(void*, int)"
          extern "char SDL_UpdateTexture(void*, void*, void*, int)"
          extern "char SDL_RenderClear(void*)"
          extern "char SDL_RenderTexture(void*, void*, void*, void*)"
          extern "char SDL_RenderPresent(void*)"
          extern "char SDL_SetRenderDrawBlendMode(void*, unsigned int)"
          extern "char SDL_SetRenderDrawColor(void*, unsigned char, unsigned char, unsigned char, unsigned char)"
          extern "char SDL_RenderGeometry(void*, void*, void*, int, void*, int)"
          extern "char SDL_GetRenderOutputSize(void*, void*, void*)"
          extern "float SDL_GetWindowPixelDensity(void*)"
          extern "unsigned int SDL_GetDisplayForWindow(void*)"
          extern "char SDL_GetDisplayUsableBounds(unsigned int, void*)"
          extern "char SDL_SetTextureColorMod(void*, unsigned char, unsigned char, unsigned char)"
          extern "char SDL_SetTextureAlphaMod(void*, unsigned char)"
          extern "char SDL_SetTextureBlendMode(void*, unsigned int)"
          extern "char SDL_PollEvent(void*)"
          extern "char SDL_WaitEvent(void*)"
          extern "char SDL_PushEvent(void*)"
          extern "void* SDL_GetKeyboardState(void*)"
          extern "void* SDL_OpenGamepad(unsigned int)"
          extern "void SDL_CloseGamepad(void*)"
          extern "char SDL_GetGamepadButton(void*, int)"
          extern "short SDL_GetGamepadAxis(void*, int)"
          extern "char SDL_InitSubSystem(unsigned int)"
          extern "void* SDL_OpenAudioDeviceStream(unsigned int, void*, void*, void*)"
          extern "char SDL_ResumeAudioStreamDevice(void*)"
          extern "char SDL_PauseAudioStreamDevice(void*)"
          extern "char SDL_ClearAudioStream(void*)"
          extern "char SDL_SetAudioStreamGain(void*, float)"
          extern "float SDL_GetAudioStreamGain(void*)"
          extern "char SDL_PutAudioStreamData(void*, void*, int)"
          extern "int SDL_GetAudioStreamQueued(void*)"
          extern "void SDL_DestroyAudioStream(void*)"
        end
      end

      private_class_method :require_fiddle!, :loadable?, :missing_message, :bind

      private

      def open_window(title, scale)
        raise_failed!("start its video") if @sdl.SDL_Init(INIT_VIDEO).zero?
        @window = @sdl.SDL_CreateWindow(title, @width * scale, @height * scale,
                                        WINDOW_RESIZABLE | WINDOW_HIGH_PIXEL_DENSITY)
        raise_failed!("open the window") if @window.null?
        @renderer = @sdl.SDL_CreateRenderer(@window, nil)
        raise_failed!("draw in the window") if @renderer.null?
        raise_failed!("keep the picture's shape") if @sdl.SDL_SetRenderLogicalPresentation(
          @renderer, @width, @height, LOGICAL_PRESENTATION_LETTERBOX
        ).zero?
        @texture = @sdl.SDL_CreateTexture(@renderer, PIXELFORMAT_XBGR1555, TEXTUREACCESS_STREAMING, @width, @height)
        raise_failed!("make the picture") if @texture.null?
        raise_failed!("keep the pixels sharp") if @sdl.SDL_SetTextureScaleMode(@texture, SCALEMODE_NEAREST).zero?
        @event = Fiddle::Pointer.malloc(EVENT_BYTES, Fiddle::RUBY_FREE)
        upload_menu_letters
        # Gamepads, where SDL can read them: a computer where it cannot plays with the keyboard alone.
        @sdl.SDL_InitSubSystem(INIT_GAMEPAD)
      end

      # The menu font's picture of every letter at the screen's density, on the screen's card (an
      # SDL texture), from which each letter of the menu's words is copied: white, as opaque as the
      # letter covers each pixel, and coloured as it is copied. A window moved to a screen of
      # another density has it put there again.
      def upload_menu_letters
        density = pixel_density
        atlas = Graphics::MenuFont.load.atlas(density)
        return if @letters_density == atlas.density

        @sdl.SDL_DestroyTexture(@letters) if live?(@letters)
        @letters = @sdl.SDL_CreateTexture(@renderer, PIXELFORMAT_ABGR8888, TEXTUREACCESS_STATIC, atlas.width,
                                          atlas.height)
        raise_failed!("make the menu's letters") if @letters.null?

        pixels = atlas.alpha.unpack("C*").flat_map { |covered| [255, 255, 255, covered] }.pack("C*")
        @sdl.SDL_UpdateTexture(@letters, nil, pixels, atlas.width * 4)
        @sdl.SDL_SetTextureBlendMode(@letters, BLENDMODE_BLEND)
        @sdl.SDL_SetTextureScaleMode(@letters, SCALEMODE_LINEAR)
        @letters_density = atlas.density
      end

      # How many of the screen's pixels a point of the window is: two on a Retina screen.
      def pixel_density = [@sdl.SDL_GetWindowPixelDensity(@window), 1.0].max

      # The biggest the window can be made, in times the picture's size, on the screen it is on.
      def largest_scale_that_fits
        room = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        return WindowMenu::SCALES.max if @sdl.SDL_GetDisplayUsableBounds(@sdl.SDL_GetDisplayForWindow(@window), room).zero?

        _, _, wide, high = room[0, 16].unpack("l4")
        [[wide / @width, high / @height].min, WindowMenu::SCALES.max].min
      end

      def live?(pointer) = pointer && !pointer.null?

      # The speaker, opened at +rate+ the first time and the same one every time after: one
      # speaker's worth of 16-bit samples, which SDL turns into whatever the computer's own sound
      # wants. Nil on a computer whose sound SDL cannot open, which then plays the game silent.
      def open_speaker_once(rate)
        return @speaker if @speaker_tried

        @speaker_tried = true
        return nil if @sdl.SDL_InitSubSystem(INIT_AUDIO).zero?

        spec = [AUDIO_S16, 1, rate].pack("Lll")
        speaker = @sdl.SDL_OpenAudioDeviceStream(AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, nil, nil)
        return nil if speaker.null?

        @sdl.SDL_ResumeAudioStreamDevice(speaker)
        @speaker_rate = rate
        @speaker = speaker
        set_speaker_volume
        speaker
      end

      def held? = @paused || @menu.open?

      # The picture last put in the window, drawn into it again, with the menu and what the window
      # is doing over it (Menu#drawing).
      def redraw_window
        @sdl.SDL_RenderClear(@renderer)
        @sdl.SDL_RenderTexture(@renderer, @texture, nil, nil)
        draw_menu_and_status
        @sdl.SDL_RenderPresent(@renderer)
      end

      # What the menu says to draw, in the window's own pixels: the picture was drawn through the
      # game's own size (the logical presentation, which scales it by a whole number with bars where
      # the window is the wrong shape), which is put aside while the menu draws and put back after.
      def draw_menu_and_status
        return unless held? || @fast_forward || @settings.frame_rate

        drawing = @menu.drawing(width: output_size.first, density: pixel_density, held: held?,
                                fast_forward: (@settings.fast_forward_speed if @fast_forward && !held?),
                                frame_rate: (@frame_rate if @settings.frame_rate))
        upload_menu_letters
        @sdl.SDL_SetRenderLogicalPresentation(@renderer, 0, 0, LOGICAL_PRESENTATION_DISABLED)
        begin
          drawing.each { |part| part.is_a?(WindowMenu::Box) ? draw_box(part) : draw_words(part) }
        ensure
          @sdl.SDL_SetRenderLogicalPresentation(@renderer, @width, @height, LOGICAL_PRESENTATION_LETTERBOX)
        end
      end

      # The window's size in the screen's own pixels.
      def output_size
        size = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        @sdl.SDL_GetRenderOutputSize(@renderer, size, size + 4)
        size[0, 8].unpack("l2")
      end

      # A box with round corners as triangles: a fan from its middle out to its edge, and round the
      # edge a band a pixel wide that fades from its colour to clear, so the edge is not jagged.
      # SDL takes each corner of a triangle as eight floats: where it is, its red, green, blue and
      # opacity from 0 to 1, and where on a texture it is (none here).
      def draw_box(box)
        ring = box_edge(box)
        red, green, blue, opacity = box.color.map { |part| part / 255.0 }
        corner = ->(x, y, alpha) { [x, y, red, green, blue, alpha, 0, 0] }
        points = [corner.call(box.x + (box.width / 2.0), box.y + (box.height / 2.0), opacity)]
        ring.each do |x, y, out_x, out_y|
          points << corner.call(x - (out_x / 2), y - (out_y / 2), opacity)
          points << corner.call(x + (out_x / 2), y + (out_y / 2), 0.0)
        end
        triangles = ring.each_index.flat_map do |at|
          inner = 1 + (2 * at)
          next_inner = 1 + (2 * ((at + 1) % ring.size))
          [0, inner, next_inner, inner, inner + 1, next_inner + 1, inner, next_inner + 1, next_inner]
        end
        @sdl.SDL_RenderGeometry(@renderer, nil, points.flatten.pack("e*"), points.size, triangles.pack("l*"),
                                triangles.size)
      end

      CORNER_STEPS = 8 # straight pieces a round corner is drawn with

      # The edge of +box+, a point at a time, each with which way is out from it: round the four
      # corners, top left first.
      def box_edge(box)
        radius = box.radius.clamp(0, [box.width, box.height].min / 2.0)
        steps = radius < 1 ? 1 : CORNER_STEPS
        middles = [[box.x + radius, box.y + radius, 180], [box.x + box.width - radius, box.y + radius, 270],
                   [box.x + box.width - radius, box.y + box.height - radius, 0],
                   [box.x + radius, box.y + box.height - radius, 90]]
        middles.flat_map do |middle_x, middle_y, from|
          (0..steps).map do |step|
            angle = (from + (90.0 * step / steps)) * Math::PI / 180
            [middle_x + (Math.cos(angle) * radius), middle_y + (Math.sin(angle) * radius), Math.cos(angle), Math.sin(angle)]
          end
        end
      end

      # Each letter of +words+ copied from the letters' card to where Menu said, in its colour.
      def draw_words(words)
        red, green, blue, opacity = words.color
        @sdl.SDL_SetTextureColorMod(@letters, red, green, blue)
        @sdl.SDL_SetTextureAlphaMod(@letters, opacity)
        words.letters.each do |letter|
          @sdl.SDL_RenderTexture(@renderer, @letters, letter.from.pack("e4"), letter.to.pack("e4"))
        end
      end

      # Pictures shown in the last whole second, for the frame rate the menu can put up.
      def count_frame_rate
        @shown_this_second += 1
        return if now - @second_began < 1

        @frame_rate = @shown_this_second
        @shown_this_second = 0
        @second_began = now
      end

      # The window made as the menu now says, where that is not as it was.
      def apply_menu_settings
        was = @settings
        @settings = @menu.settings
        @closed = true if @menu.quit?
        if @settings.scale != was.scale
          @sdl.SDL_SetWindowSize(@window, @width * @settings.scale, @height * @settings.scale)
        end
        @sdl.SDL_SetWindowFullscreen(@window, @settings.fullscreen ? 1 : 0) if @settings.fullscreen != was.fullscreen
        set_speaker_volume
      end

      def set_speaker_volume
        return unless live?(@speaker)

        @sdl.SDL_SetAudioStreamGain(@speaker, @settings.muted ? 0.0 : @settings.volume / 100.0)
      end

      # The speaker stopped, with what it had waiting thrown away: it would otherwise play late.
      def empty_speaker
        return unless live?(@speaker)

        @sdl.SDL_PauseAudioStreamDevice(@speaker)
        @sdl.SDL_ClearAudioStream(@speaker)
      end

      def resume_speaker
        @sdl.SDL_ResumeAudioStreamDevice(@speaker) if live?(@speaker)
      end

      # Everything SDL has heard from the window.
      def read_events
        read_event while @sdl.SDL_PollEvent(@event) != 0
      end

      # One thing SDL heard, in @event: a closed window, or the last window gone, stops the play;
      # F1 (or the key above Tab) opens or closes the menu, and while it is open the arrows and
      # Enter work it; P going down pauses or carries on; and Tab fast forwards from going down to
      # coming up. A key held down is heard going down again and again: only the first time counts,
      # but for the arrows in the menu, which then move on as a held key does in any list. A
      # gamepad's buttons work the menu too (#read_pad_button).
      def read_event
        type = @event[0, 4].unpack1("L")
        @closed = true if type == EVENT_QUIT || type == EVENT_WINDOW_CLOSE_REQUESTED
        return open_or_close_pad(type) if type == EVENT_GAMEPAD_ADDED || type == EVENT_GAMEPAD_REMOVED
        return read_pad_button(type == EVENT_PAD_BUTTON_DOWN) if type == EVENT_PAD_BUTTON_DOWN || type == EVENT_PAD_BUTTON_UP
        return unless type == EVENT_KEY_DOWN || type == EVENT_KEY_UP

        scancode = @event[KEY_SCANCODE_AT, 4].unpack1("L")
        if type == EVENT_KEY_UP
          @kept_from_game.delete(scancode)
          @fast_forward = false if scancode == FAST_FORWARD
        else
          read_key_down(scancode, @event[KEY_REPEAT_AT, 1].unpack1("C").nonzero?)
        end
      end

      # A gamepad plugged in is opened and read from then on, and one pulled out is let go. SDL
      # says the same of every pad already plugged in when the window opens.
      def open_or_close_pad(type)
        id = @event[PAD_ID_AT, 4].unpack1("L")
        if type == EVENT_GAMEPAD_ADDED
          pad = @sdl.SDL_OpenGamepad(id)
          @pads[id] = pad if live?(pad)
        elsif (pad = @pads.delete(id))
          @sdl.SDL_CloseGamepad(pad)
        end
      end

      # The console's buttons one gamepad holds now.
      def pad_held(pad)
        down = (PAD_BUTTONS.keys - @pad_kept).select { |button| @sdl.SDL_GetGamepadButton(pad, button) != 0 }
        self.class.pad_buttons(down: down, stick_x: @sdl.SDL_GetGamepadAxis(pad, PAD_LEFT_X),
                               stick_y: @sdl.SDL_GetGamepadAxis(pad, PAD_LEFT_Y))
      end

      # A gamepad's button went down, or came up. The guide button, or Back and Start together,
      # opens or closes the menu, and while it is open the D-pad, A and B work it. Back and Start
      # each come as an event of their own, and only the second of them, with the first still
      # down, opens it. A button pressed for the menu is kept from the game until it comes up.
      def read_pad_button(down)
        id = @event[PAD_ID_AT, 4].unpack1("L")
        button = @event[PAD_BUTTON_AT, 1].unpack1("C")
        unless down
          @pad_down[id].delete(button)
          return @pad_kept.delete(button)
        end

        @pad_down[id] << button
        return unless @has_menu

        if PAD_OPENERS.include?(button) || pad_openers_together?(id, button)
          @menu.toggle
          @pad_kept.concat(PAD_OPENERS.include?(button) ? [button] : PAD_OPENERS_TOGETHER)
        elsif @menu.open? && PAD_MENU_KEYS.key?(button)
          @pad_kept << button
          press_menu(PAD_MENU_KEYS[button])
        end
      end

      def pad_openers_together?(id, button)
        PAD_OPENERS_TOGETHER.include?(button) && (PAD_OPENERS_TOGETHER - @pad_down[id]).empty? &&
          !(PAD_OPENERS_TOGETHER - @pad_kept).empty?
      end

      # A key meant for the menu, and the window made as the menu then says. Resume carries on,
      # even from a pause before the menu was opened; closing the menu (the gamepad's B) leaves
      # such a pause as it was, as F1 does.
      def press_menu(key)
        @menu.press(key)
        @paused = false unless @menu.open? || key == :close
        apply_menu_settings
      end

      def read_key_down(scancode, repeat)
        if MENU_OPENERS.include?(scancode) && @has_menu
          @menu.toggle unless repeat
        elsif @menu.open? && MENU_KEYS.key?(scancode)
          @kept_from_game << scancode
          press_menu(MENU_KEYS[scancode]) unless repeat && MENU_KEYS[scancode] == :enter
        elsif scancode == FAST_FORWARD
          @fast_forward = true
        elsif scancode == PAUSE && !@menu.open?
          @paused = !@paused unless repeat
        end
      end

      def raise_failed!(what)
        raise Failed, "SDL cannot #{what}: #{@sdl.SDL_GetError}."
      end
    end
  end
end
