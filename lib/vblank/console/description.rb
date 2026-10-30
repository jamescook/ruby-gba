# frozen_string_literal: true

module VBlank
  module Console
    # WHAT A CONSOLE IS, AS FAR AS A GAME CAN TELL: how big its screen is, which buttons it has, how
    # many sprites it shows, and which of the picture's tricks it can do at all. The builder, the
    # build checks and the interpreter read these, so a game is laid out, checked and played for the
    # screen it will be shown on.
    #
    # It says nothing about HOW the console is driven — register addresses, memory, the processor —
    # which is each lowering's own business (Console::Hardware is the Advance's). A program carries
    # the name of the console it was built for, and anything that reads it asks
    # Program#described_console.
    #
    # +name+ is how a game and the command line name it (:gba), +title+ how a person does.
    # +screen_width+ and +screen_height+ are in pixels. +buttons+ are the ones it has, in the
    # order IR::Buttons names them. +sprites+ is how many it can show at once, and +sprite_places+
    # how many a game can keep places for: more than it shows where a cartridge keeps a bigger
    # copy of its table and puts the sprites showing into the console's each frame, as the
    # Advance's does (Backends::GBA::SpriteDrawing::HeldTable), and the same where it does not.
    # +sprites_a_row+ is how many pieces of sprites, eight pixels wide, it draws on one row of the
    # screen before it leaves the rest of that row's out, or nil where the build does not count
    # them. +backgrounds+ is how many tiled layers it stacks, +turning_backgrounds+ how many of
    # them can turn and resize, and +backgrounds_beside_turning+ how many still scroll on a screen
    # where one turns. +bar_is_a_background+ says whether a status bar is one of those layers, or a
    # layer the console keeps beside them. +turning_sprites+ says whether a sprite can turn and resize.
    # +cuts_sprites+ says whether its build draws every sprite's picture in pieces of 8×8, so a
    # picture the game paints from a list can be any size in whole pieces, not only a size one
    # sprite of the console is drawn at.
    # +blends+ says whether its display can mix colours as it draws —
    # fade the finished picture, mix one layer into another — rather than only change the colours
    # in its lists. +mixes_by_half+ says whether, without blending by degrees, it can still show a
    # layer half see-through — the Super Nintendo's colour math adds what is behind a layer to it
    # and halves the sum — which an amount the build rounds to an even half asks for, and nothing
    # else. +list_colors+ is how many places a list of colours holds. +painted_pages+ is
    # how many pictures a tear-free painted screen keeps: two where one is drawn while the other
    # is shown, one where the console only ever shows a picture whole. +clock_keeps_date+ says
    # whether the clock chip its cartridges carry holds the date and time, or only counts the days
    # and the time of day since it started (IR::Clock). +extension+ ends the name of a cartridge
    # file for it.
    #
    # +cycles_a_second+ is the clock the display counts in, and +cycles_a_frame+ how many of those
    # it takes to draw one picture and the gap after it: together they are how long a frame is,
    # which anything that keeps real seconds by counting frames needs. Neither console shows
    # exactly sixty a second. +samples_a_copy+ is how many samples of mixed sound one copy hands
    # the console's sound hardware, which decides the rates a mix can run at
    # (Console::SampleClock), or nil where the processor hands it no samples. The timer that says when
    # the next sample is due counts in +sample_timer_step+ of those cycles at a time, and at most
    # +sample_timer_counts+ of them, so it can only wait a whole number of steps up to that many.
    # +recordings_at_once+ is how many recordings sound together; a play past that is dropped.
    # +mixes_recordings+ says whether a recording can be shaped (`envelope:`), its loudness moved
    # sample by sample: the processor adds them up into a stream of its own, or the sound chip's
    # voices do that themselves. One that does neither plays a recording a sample at a time, all
    # or nothing, on a voice of the sound chip. +recording_voice_hz+ is, for a console whose
    # sound chip plays each recording on a voice of its own rather than having the processor mix
    # them, how many samples a second those voices read; nil elsewhere. +voice_output_hz+ is how
    # often it hands its sound chip's voices on to the speaker, which matters to the noise voice alone:
    # a hiss can step faster than that, and what is heard of one that does is whichever way it
    # stood at each of those moments, a hiss of its own and a lower one. A backend that makes the
    # sound itself looks at the hiss at the same moments to make the same one. +largest_memory_bytes+ is how
    # many bytes the largest memory a game's lists and pools are kept in holds: one pool is kept
    # whole in one memory, so no pool can be bigger.
    #
    # How much a game can keep, which the build checks count against (Checks::IwramBudget):
    # +work_memory_bytes+ is the memory every variable lives in, +work_memory_kept_bytes+ how much
    # of it the build keeps for itself (the stack, the copy of the sprite table), and
    # +roomier_memory_bytes+ the memory beside it that only lists and pools can move to, 0 where
    # there is none.
    #
    # +sprites_placed_before_wait+ says where a game loop's pass places the frame's sprites and
    # scroll (IR::Frames.loop_in_console_order). A console that writes them straight into its display
    # in the gap between frames places them after the wait, from the pass just ended. One that
    # sends them from a copy as the wait ends places them before it, or they would show a frame
    # later than the pass that moved them.
    #
    # +rumbles+ says a game's `rumble` is felt: the cartridge carries a motor the game turns on and
    # off. Where it is not, the verb does nothing, since a game plays the same without it.
    Description = Data.define(:name, :title, :screen_width, :screen_height, :buttons, :sprites, :sprite_places,
                              :sprites_a_row, :turning_sprites, :cuts_sprites, :backgrounds, :turning_backgrounds,
                              :backgrounds_beside_turning, :bar_is_a_background, :blends, :mixes_by_half, :list_colors,
                              :painted_pages,
                              :clock_keeps_date, :cycles_a_second, :cycles_a_frame, :samples_a_copy,
                              :sample_timer_step, :sample_timer_counts, :recordings_at_once, :mixes_recordings,
                              :recording_voice_hz,
                              :voice_output_hz, :largest_memory_bytes, :work_memory_bytes, :work_memory_kept_bytes,
                              :roomier_memory_bytes, :sprites_placed_before_wait, :rumbles, :extension) do
      def screen_size = [screen_width, screen_height]

      # How much of the work memory is free for a game's own variables and lists.
      def free_work_memory_bytes = work_memory_bytes - work_memory_kept_bytes

      # Whether there is a roomier memory beside the work memory for lists and pools to move to.
      def roomier_memory? = roomier_memory_bytes.positive?

      # How long one frame is, in seconds.
      def frame_seconds = Rational(cycles_a_frame, cycles_a_second)

      # The clock a mix of recordings runs at, as near +hz+ as this console's sound can keep up
      # with (see Console::SampleClock) — or, where each recording plays on a voice of the sound
      # chip, the rate those voices read at, whatever +hz+ is.
      def sample_clock(hz)
        recording_voice_hz ? SampleClock.on_voices(recording_voice_hz, self) : SampleClock.nearest(hz, self)
      end

      # Whether any of its backgrounds can turn and resize.
      def turns_backgrounds? = turning_backgrounds.positive?

      # How many backgrounds scroll at one time, on a screen where one turns or where none does.
      def scrolling_backgrounds(turning:) = turning ? backgrounds_beside_turning : backgrounds

      # The middle of the screen, in whole pixels.
      def middle = [screen_width / 2, screen_height / 2]
    end

    # The Game Boy Advance.
    ADVANCE = Description.new(name: :gba, title: "Game Boy Advance", screen_width: 240, screen_height: 160,
                              buttons: %i[a b select start right left up down r l].freeze, sprites: 128,
                              # The most the desktop and web builds draw in one frame, too.
                              sprite_places: 512,
                              # What limits a row on the Advance is the time the display has to
                              # draw it, which depends on how wide each sprite is and whether it
                              # turns, and the build does not work that out.
                              sprites_a_row: nil, turning_sprites: true, cuts_sprites: false,
                              # Four layers that scroll, or two that scroll and one that turns.
                              backgrounds: 4, turning_backgrounds: 1, backgrounds_beside_turning: 2,
                              # A status bar is one of those layers.
                              bar_is_a_background: true,
                              blends: true, mixes_by_half: false, list_colors: 16, painted_pages: 2, clock_keeps_date: true,
                              # 228 lines of 1232 cycles: 160 drawn, and 68 the gap after.
                              cycles_a_second: 16_777_216, cycles_a_frame: 280_896,
                              # The sound copy moves four 32-bit words at a time: sixteen 8-bit samples.
                              samples_a_copy: 16,
                              # ...on a timer counting every cycle, up to its 16 bits.
                              sample_timer_step: 1, sample_timer_counts: 65_536,
                              # The framework's number, not the hardware's (Audio::Sound::MIXER_VOICES).
                              recordings_at_once: 16, mixes_recordings: true,
                              # The voices are mixed into the speaker's output at the rate the
                              # sound's bias register starts at, which no cartridge built here changes.
                              recording_voice_hz: nil, voice_output_hz: 32_768,
                              # The 256K of roomier memory beside the 32K quick one.
                              largest_memory_bytes: 256 * 1024,
                              # The 32K quick memory, 4K of it the stack and the framework's own.
                              work_memory_bytes: 32 * 1024, work_memory_kept_bytes: 4 * 1024,
                              roomier_memory_bytes: 256 * 1024,
                              # The sprite table and the scroll are written straight into the
                              # console in the gap after the wait, and show on the frame after it.
                              sprites_placed_before_wait: false,
                              # Its rumble cartridges are not made here yet: nothing is felt.
                              rumbles: false, extension: ".gba")

    # The Game Boy Color: a smaller screen, eight buttons, forty sprites and ten on a row, one
    # background, nothing that turns, lists of four colours, and a clock that counts days. What
    # each verb does on it is Console::ColorAnswers's to say.
    COLOR = Description.new(name: :gbc, title: "Game Boy Color", screen_width: 160, screen_height: 144,
                            buttons: %i[a b select start right left up down].freeze, sprites: 40, sprite_places: 40,
                            sprites_a_row: 10, turning_sprites: false, cuts_sprites: false,
                            backgrounds: 1, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                            # A status bar is the window, a layer beside the one background.
                            bar_is_a_background: false,
                            blends: false, mixes_by_half: false, list_colors: 4, painted_pages: 1, clock_keeps_date: false,
                            # 154 lines of 456 cycles: the Advance's frame exactly, on a clock a
                            # quarter as fast. Double speed doubles the cycles, not the frames.
                            cycles_a_second: 4_194_304, cycles_a_frame: 70_224,
                            # One recording at a time, a sample each time the timer runs out,
                            # handed to the sound chip by the processor itself. The timer counts
                            # every sixteenth cycle of the processor, which runs at double speed:
                            # every eighth of these. It holds a byte, so it waits 256 counts at most.
                            samples_a_copy: 1, sample_timer_step: 8, sample_timer_counts: 256,
                            recordings_at_once: 1, mixes_recordings: false,
                            # Nothing stands between the voices and the speaker: every step of the
                            # hiss is heard, which is every tick of the noise voice's own clock
                            # (Audio::Sound::NOISE_CLOCK_HZ) at the most. The emulator the tests
                            # play in takes a sample every 32 cycles instead and averages the hiss
                            # over each, which is its own approximation of the same thing.
                            recording_voice_hz: nil, voice_output_hz: 524_288,
                            # The 8K of work memory in view at once (see Backends::GBC::Memory),
                            # and nothing beside. The stack, the copy of the sprite table and the
                            # runtime's own state are in it before any variable, which the Color
                            # lowering's tests hold this to (test_gbc_memory.rb).
                            largest_memory_bytes: 8 * 1024,
                            work_memory_bytes: 8 * 1024, work_memory_kept_bytes: 1536,
                            roomier_memory_bytes: 0,
                            # The sprite table and the scroll are sent from a copy as the wait
                            # ends, so a pass's are placed before it to show on the frame after.
                            sprites_placed_before_wait: true,
                            # A cartridge with a motor, for a game that rumbles (Runtime::Rumble).
                            rumbles: true, extension: ".gbc")

    # The Super Nintendo: a wider and taller screen than the Advance's, twelve buttons (a game reads
    # the ten the Advance has), 128 sprites and 34 pieces of them on a row, backgrounds of tiles,
    # nothing that turns but one layer the build does not use, lists of sixteen colours. What each
    # verb does on it is Console::SNESAnswers's to say.
    SUPER_NINTENDO = Description.new(name: :snes, title: "Super Nintendo", screen_width: 256, screen_height: 224,
                                     buttons: %i[a b select start right left up down r l].freeze, sprites: 128,
                                     sprite_places: 128,
                                     # A row of the screen shows at most 32 sprites and 34 of their
                                     # 8-pixel pieces; a piece is what this counts.
                                     sprites_a_row: 34, turning_sprites: false,
                                     # Every sprite picture is cut into 8×8 pieces (Backends::SNES::Art).
                                     cuts_sprites: true,
                                     # The build shows a game's backgrounds on the arrangement of
                                     # layers called mode 1: two of sixteen colours and one of four.
                                     # Mode 7 turns one layer, alone; the build does not use it.
                                     backgrounds: 2, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                                     bar_is_a_background: true,
                                     # Its colour maths adds, subtracts or halves, never the
                                     # Advance's sixteen steps, so a fade is walked colour by colour.
                                     blends: false, mixes_by_half: true, list_colors: 16,
                                     # A painted screen is copied whole to the console before it
                                     # is shown, as the Color's is.
                                     painted_pages: 1, clock_keeps_date: false,
                                     # 262 lines of 1364 cycles of the console's master clock, less
                                     # four cycles every other frame: sixty frames a second and a little.
                                     cycles_a_second: 21_477_270, cycles_a_frame: 357_366, samples_a_copy: nil,
                                     # No timer hands the sound chip samples: its eight voices each
                                     # read a recording of their own, and loop it, pitch it and
                                     # scale it themselves.
                                     sample_timer_step: nil, sample_timer_counts: nil,
                                     recordings_at_once: 8, mixes_recordings: true,
                                     # The sound chip's voices are mixed 32000 times a second, and
                                     # each plays a recording of its own at that rate.
                                     recording_voice_hz: 32_000, voice_output_hz: 32_000,
                                     # Lists and pools go in the 120K of work RAM past the first 8K,
                                     # 64K of it to one.
                                     largest_memory_bytes: 64 * 1024,
                                     # The first 8K of work RAM is in view from the cartridge's code, so
                                     # every variable is there; the stack and the runtime's own state
                                     # take some of it first (see Backends::SNES::Memory).
                                     work_memory_bytes: 8 * 1024, work_memory_kept_bytes: 2048,
                                     roomier_memory_bytes: 120 * 1024,
                                     # The sprite table and the scroll are sent from a copy in the
                                     # gap after the wait, from the pass just ended, as the Advance's
                                     # are written.
                                     sprites_placed_before_wait: false,
                                     # No cartridge with a motor is made for it.
                                     rumbles: false, extension: ".sfc")

    # Each console's description is reached through its kit (Console::Kit, Console.described).

    # The consoles a game says it is for, as a frozen list of names: one name or a list of them.
    # A name no console has, or no name at all, is refused, since no console is the one a game is
    # for when it does not say. +setting+ is what the game wrote them in (`consoles:` where the
    # game is named, `t.consoles` in its Rakefile), so both are checked alike and the refusal says
    # which.
    def self.refuse_unknown_consoles!(consoles, setting:)
      named = Array(consoles).map(&:to_sym)
      named.each { |name| described(name) }
      if named.empty?
        raise ArgumentError, "#{setting} names no console. Name the consoles the game is for: " \
                             "`%i[gba]` for the Game Boy Advance alone, or `%i[gba gbc]` for the Game Boy Color too."
      end

      named.freeze
    end
  end
end
