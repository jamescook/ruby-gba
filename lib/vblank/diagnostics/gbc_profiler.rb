# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHERE A GAME BOY COLOR CARTRIDGE'S FRAMES WENT, measured by running it — the Color's own
    # profiler, beside the Advance's (Profiler), which it shares nothing with but the idea.
    #
    # The emulator plays the cartridge an instruction at a time and counts the cycles each one
    # took (Core#profile_gb). Every instruction is in a routine: one of the game's, which the build
    # recorded the addresses of beside what it is to the author (GBC::Places#routine_at), or one of
    # the runtime's, found by the runtime's label before it (GBC::Places#code), so the time comes
    # back by routine without a label being read. Asleep, waiting for the screen, is counted apart: it is the part of
    # each frame the game did not need. How many passes of the game loop the frames held is the
    # runtime's own count, so the frame rate is the one the game really played at.
    class GBCProfiler
      SETTLE = 20
      FRAMES = 60

      # The console draws this many frames a second.
      FRAME_RATE = 59.73

      # One routine and its share of every cycle measured, from 0 to 1.
      Spent = Data.define(:routine, :share)

      # What a run came to: the frames measured, how many passes of the game loop they held, the
      # frame rate that is, how much of the time the game was asleep, and the routines by share,
      # the game's and the runtime's apart. +lists_missed+ is how many times a sprite found none
      # of the console's eight lists of sprite colours free, in a game whose sprites wear more
      # lists than eight (GBC::Art#lends?), and was drawn in another list's colours; nil for a
      # game that lends none.
      Result = Data.define(:frames, :passes, :fps, :idle_share, :game, :runtime, :lists_missed) do
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h))
      end

      # +rom+ is a GBCROM built with its record (GBC::Places). +keys+ are held from power-on.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        Emulator.load!
        new(rom).measure(frames: frames, settle: settle, keys: keys)
      end

      def initialize(rom)
        @rom = rom
        @places = rom.built or raise ArgumentError, "this cartridge carries no record of its build to name its routines by"
        @labels = @places.code.map { |label, place| [counted_key(place), label] }.sort
        @starts = @labels.map(&:first)
      end

      def measure(frames:, settle:, keys:)
        Emulator.with_cartridge(@rom, file_name: "game.gbc") do |core|
          core.set_keys(IR::Buttons.mask(keys))
          settle.times { core.run_frame }
          before = passes(core)
          missed_before = lists_missed(core)
          counted = core.profile_gb(frames)
          missed = missed_before && (lists_missed(core) - missed_before)
          result_of(counted, frames, passes(core) - before, missed)
        end
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Game Boy Color: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), asleep #{percent(result.idle_share)} of the time."
        if result.lists_missed&.positive?
          times = result.lists_missed == 1 ? "1 time" : "#{result.lists_missed} times"
          out.puts "", "A sprite found none of the console's eight lists of colours free #{times}. Each time, the " \
                       "sprite showed the colours of another list. The sprites on the screen used more than eight " \
                       "lists, or a list started on the same pass that another stopped. To fix this, use fewer " \
                       "lists of colours for the sprites that are on the screen at the same time."
        end
        { "Your routines" => result.game, "The runtime" => result.runtime }.each do |heading, spent|
          next if spent.empty?

          out.puts "", "#{heading}:"
          spent.first(12).each { |row| out.puts format("  %6s  %s", percent(row.share), row.routine) }
        end
      end

      def self.percent(share) = format("%.1f%%", share * 100)

      private

      def passes(core) = core.bus_read32(@places.runtime.fetch(IR::Backends::GBC::Runtime::Frame::PASSES))

      # How many times so far a sprite found the eight lists of colours in use, or nil for a game
      # that lends none.
      def lists_missed(core)
        lent = @places.runtime[IR::Backends::GBC::Runtime::Picture::LENT] or return nil
        core.bus_read16(lent + IR::Backends::GBC::Runtime::Picture::LENT_MISSED)
      end

      # The runtime's HALT instructions — waiting for the screen, and stopped for good. The emulator
      # charges a sleep to the instruction that went to sleep, so their cycles are the sleep.
      SLEEPS = %w[rt_sleep_until_vblank_halt rt_stopped].freeze

      def result_of(counted, frames, passes, missed)
        total = counted[:total].to_f
        spent = counted[:spent].dup
        sleeps = SLEEPS.filter_map { |label| @places.code[label] }.map { |place| counted_key(place) }
        asleep = counted[:halted] + sleeps.sum { |key| spent.delete(key) || 0 }
        game = Hash.new(0)
        runtime = Hash.new(0)
        spent.each do |key, cycles|
          routine = @places.routine_at(key >> 16, key & 0xFFFF)
          routine ? game[routine] += cycles : runtime[runtime_part_at(key)] += cycles
        end
        Result.new(frames: frames, passes: passes, fps: passes * FRAME_RATE / frames,
                   idle_share: asleep / total, game: by_share(game, total), runtime: by_share(runtime, total),
                   lists_missed: missed)
      end

      def by_share(cycles_by_routine, total)
        cycles_by_routine.sort_by { |_, cycles| -cycles }.map { |routine, cycles| Spent.new(routine: routine, share: cycles / total) }
      end

      # The key the emulator counts an instruction's cycles under: its bank × 0x10000 plus its
      # address, since an address past the first bank means nothing without the bank in view.
      def counted_key(place) = (place.bank * 0x10000) + place.address

      # The part of the runtime an instruction at +key+ (see #counted_key) is in, which is not the
      # game's: the runtime's label before it, each of which is the name of a routine of its own.
      def runtime_part_at(key)
        return "the sprite table's copy, run from quick memory" if key.between?(0x8000, 0xFFFF)

        at = (@starts.bsearch_index { |start| start > key } || @starts.length) - 1
        return "somewhere with no label" if at.negative?

        @labels[at][1]
      end
    end
  end
end
