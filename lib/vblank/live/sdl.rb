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
    # The keys: the arrows are the pad, Z is A, X is B, Enter is Start, Backspace is Select, A and
    # S are the shoulder buttons L and R. As in the desktop build, P pauses and carries on, and Tab
    # held fast forwards. Escape, or closing the window, stops the play.
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
      PIXELFORMAT_XBGR1555 = 0x15530f02
      TEXTUREACCESS_STREAMING = 1
      SCALEMODE_NEAREST = 0
      LOGICAL_PRESENTATION_LETTERBOX = 2
      EVENT_QUIT = 0x100
      EVENT_WINDOW_CLOSE_REQUESTED = 0x210
      EVENT_KEY_DOWN = 0x300
      EVENT_KEY_UP = 0x301
      KEY_SCANCODE_AT = 24 # where in a key's event the key is, as a scancode (4 bytes)
      KEY_DOWN_AT = 36 # ...whether it went down (1 byte)
      KEY_REPEAT_AT = 37 # ...and whether it is a key held down, heard again (1 byte)
      EVENT_BYTES = 128 # an SDL_Event is a union of at most this many bytes
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
      KEYS = Ractor.make_shareable({ right: 79, left: 80, down: 81, up: 82, a: 29, b: 27, start: 40, select: 42,
                                     l: 4, r: 22 })
      ESCAPE = 41
      PAUSE = 19 # P, the desktop build's pause key too
      FAST_FORWARD = 43 # Tab, held, as in the desktop build and many an emulator

      # Whether SDL3 can be found and loaded here, without opening anything.
      def self.available?(library: nil)
        binding_for(library)
        true
      rescue Missing
        false
      end

      # A window +scale+ times a +width+ by +height+ picture, titled +title+. +library+ names the
      # SDL3 file to load, in place of looking for it. A window that cannot be opened all the way
      # is closed again before the error comes out.
      def initialize(title:, scale: 3, width: 240, height: 160, library: nil)
        @sdl = self.class.binding_for(library)
        @width = width
        @height = height
        @closed = false
        begin
          open_window(title, scale)
        rescue Failed
          close
          raise
        end
      end

      # The picture into the window, and whatever SDL has heard from the window since. The
      # picture is the size the window was opened for.
      def show(pixels, width, height)
        unless [width, height] == [@width, @height] && pixels.length == width * height
          raise ArgumentError, "The window shows a #{@width}x#{@height} picture, and it was given a " \
                               "#{width}x#{height} picture of #{pixels.length} pixels."
        end

        read_events
        @sdl.SDL_UpdateTexture(@texture, nil, pixels.pack("v*"), @width * 2)
        redraw_window
      end

      # The console's buttons whose keys are down now, as SDL last heard them (#show reads what
      # SDL has heard). The keyboard is read when it is asked, whichever pass it is asked for.
      def held_buttons(_pass)
        keys = @sdl.SDL_GetKeyboardState(nil)
        KEYS.filter_map { |button, code| button if keys[code] != 0 }
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

      # Tab is held, as SDL last heard it (#show reads what SDL has heard), whichever pass it is
      # asked for.
      def fast_forward?(_pass) = @fast_forward == true

      # P was pressed (#show reads what SDL has heard): the window holds, the picture up and the
      # speaker emptied and silent, until P is pressed again or the play is stopped. It waits on
      # SDL for the next thing to happen to the window, so a pause takes no time from the computer,
      # and draws the picture again after each, so a window resized while paused is not left blank.
      # Says whether it held.
      def hold_while_paused
        return false unless @paused

        empty_speaker
        while @paused && !stop?
          read_event if @sdl.SDL_WaitEvent(@event) != 0
          redraw_window
        end
        resume_speaker
        true
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def wait_until(seconds)
        ahead = seconds - now
        sleep(ahead) if ahead.positive?
      end

      # The window goes, and SDL with it. Closing twice does nothing more.
      def close
        @sdl.SDL_DestroyAudioStream(@speaker) if live?(@speaker)
        @speaker = nil
        @sdl.SDL_DestroyTexture(@texture) if live?(@texture)
        @sdl.SDL_DestroyRenderer(@renderer) if live?(@renderer)
        @sdl.SDL_DestroyWindow(@window) if live?(@window)
        @texture = @renderer = @window = nil
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
          extern "char SDL_PollEvent(void*)"
          extern "char SDL_WaitEvent(void*)"
          extern "char SDL_PushEvent(void*)"
          extern "void* SDL_GetKeyboardState(void*)"
          extern "char SDL_InitSubSystem(unsigned int)"
          extern "void* SDL_OpenAudioDeviceStream(unsigned int, void*, void*, void*)"
          extern "char SDL_ResumeAudioStreamDevice(void*)"
          extern "char SDL_PauseAudioStreamDevice(void*)"
          extern "char SDL_ClearAudioStream(void*)"
          extern "char SDL_PutAudioStreamData(void*, void*, int)"
          extern "int SDL_GetAudioStreamQueued(void*)"
          extern "void SDL_DestroyAudioStream(void*)"
        end
      end

      private_class_method :require_fiddle!, :loadable?, :missing_message, :bind

      private

      def open_window(title, scale)
        raise_failed!("start its video") if @sdl.SDL_Init(INIT_VIDEO).zero?
        @window = @sdl.SDL_CreateWindow(title, @width * scale, @height * scale, WINDOW_RESIZABLE)
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
      end

      # The picture last put in the window, drawn into it again.
      def redraw_window
        @sdl.SDL_RenderClear(@renderer)
        @sdl.SDL_RenderTexture(@renderer, @texture, nil, nil)
        @sdl.SDL_RenderPresent(@renderer)
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
      # P going down pauses or carries on; and Tab fast forwards from going down to coming up. A
      # key held down is heard going down again and again, and only the first time counts.
      def read_event
        type = @event[0, 4].unpack1("L")
        @closed = true if type == EVENT_QUIT || type == EVENT_WINDOW_CLOSE_REQUESTED
        return unless type == EVENT_KEY_DOWN || type == EVENT_KEY_UP

        scancode = @event[KEY_SCANCODE_AT, 4].unpack1("L")
        down = type == EVENT_KEY_DOWN
        @fast_forward = down if scancode == FAST_FORWARD
        @paused = !@paused if scancode == PAUSE && down && @event[KEY_REPEAT_AT, 1].unpack1("C").zero?
      end

      def raise_failed!(what)
        raise Failed, "SDL cannot #{what}: #{@sdl.SDL_GetError}."
      end
    end
  end
end
