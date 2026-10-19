# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # WHERE A GAME BOY COLOR CARTRIDGE'S FRAMES WENT, measured by running it — the Color's own
    # profiler, beside the Advance's (Profiler), which it shares nothing with but the idea.
    #
    # The emulator plays the cartridge an instruction at a time and counts the cycles each one
    # took (Core#profile_gb). Every instruction is in a routine — one of the game's, or one of the
    # runtime's — found by the label before it in the cartridge (GBC::Places#code), so the time
    # comes back by routine. Asleep, waiting for the screen, is counted apart: it is the part of
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
      # the game's and the runtime's apart.
      Result = Data.define(:frames, :passes, :fps, :idle_share, :game, :runtime) do
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
          core.set_keys(IR::Backends::Native::HeadlessRun.button_mask(keys))
          settle.times { core.run_frame }
          before = passes(core)
          counted = core.profile_gb(frames)
          result_of(counted, frames, passes(core) - before)
        end
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Game Boy Color: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), asleep #{percent(result.idle_share)} of the time."
        { "Your routines" => result.game, "The runtime" => result.runtime }.each do |heading, spent|
          next if spent.empty?

          out.puts "", "#{heading}:"
          spent.first(12).each { |row| out.puts format("  %6s  %s", percent(row.share), row.routine) }
        end
      end

      def self.percent(share) = format("%.1f%%", share * 100)

      private

      def passes(core) = core.bus_read32(@places.runtime.fetch(IR::Backends::GBC::Runtime::Frame::PASSES))

      # The runtime's HALT instructions — waiting for the screen, and stopped for good. The emulator
      # charges a sleep to the instruction that went to sleep, so their cycles are the sleep.
      SLEEPS = %w[rt_sleep_until_vblank rt_stopped].freeze

      def result_of(counted, frames, passes)
        total = counted[:total].to_f
        spent = counted[:spent].dup
        sleeps = SLEEPS.filter_map { |label| @places.code[label] }.map { |place| counted_key(place) }
        asleep = counted[:halted] + sleeps.sum { |key| spent.delete(key) || 0 }
        by = Hash.new(0)
        spent.each { |key, cycles| by[routine_at(key)] += cycles }
        game, runtime = by.sort_by { |_, cycles| -cycles }
                          .map { |routine, cycles| Spent.new(routine: routine, share: cycles / total) }
                          .partition { |row| game_routine?(row.routine) }
        Result.new(frames: frames, passes: passes, fps: passes * FRAME_RATE / frames,
                   idle_share: asleep / total, game: game, runtime: runtime)
      end

      # The key the emulator counts an instruction's cycles under: its bank × 0x10000 plus its
      # address, since an address past the first bank means nothing without the bank in view.
      def counted_key(place) = (place.bank * 0x10000) + place.address

      # The routine an instruction at +key+ (see #counted_key) is in, by the game's name
      # for it where it is the game's.
      def routine_at(key)
        return "the sprite table's copy, run from quick memory" if key.between?(0x8000, 0xFFFF)

        at = (@starts.bsearch_index { |start| start > key } || @starts.length) - 1
        return "somewhere with no label" if at.negative?

        readable(@labels[at][1])
      end

      # A label as the routine it is in: "game_f_update_ball" and "f_update_ball.end_if12" are both
      # update_ball, and a routine cut into parts is one routine.
      def readable(label)
        routine = label.split(".").first.delete_prefix("game_").sub(/_part\d+\z/, "")
        case routine
        when "rg_game_main" then "the game loop"
        when /\Af__scene_(\w+)\z/ then "scene :#{Regexp.last_match(1)}"
        when /\Af_(\w+)\z/ then Regexp.last_match(1)
        else routine
        end
      end

      def game_routine?(name) = !name.start_with?("rt_", "rg_", "art_", "music_", "somewhere")
    end
  end
end
