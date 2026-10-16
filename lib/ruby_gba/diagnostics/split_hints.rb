# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # WHICH PART OF A ROUTINE TOO BIG FOR THE QUICK MEMORY TO MAKE A `func` OF.
    #
    # The console's quick memory runs code about two and a third times faster than the
    # cartridge, and a routine goes in whole or not at all. One that grows past the room runs
    # entirely from the cartridge — a game's play screen, say — though most of its time is
    # usually spent in a small part of it, and that part would fit.
    #
    # The build does not take a game's routine apart on its own: cutting code out of the middle
    # of somebody's routine is a place for bugs to hide, and the author knows where the seams in
    # their own game are. So a measured run says it instead. The build keeps, for each routine
    # that missed, where each of its statements' code is and the line that wrote it; the run says
    # how long the console spent at each address; and between them each statement has a share of
    # the routine's time and a size. The part worth a `func` is the one holding the most time
    # that still fits.
    #
    # WHAT FITS is the room the quick memory has spare, and the room of every routine kept there
    # that the frame spent less time in than this part: the build chooses by time, so a `func`
    # busier than those would take their place.
    module SplitHints
      # One part worth a `func`: the routine it is in, the line that wrote it, its share of that
      # routine's time and of the frame's (in per cent), how big its code is, and whether it
      # fits in +room+, the bytes it could have.
      Hint = Data.define(:routine, :source, :share, :frame_share, :bytes, :fits, :room)

      # A part has to be worth a line of the report: this much of its routine's time, and this
      # much of the frame's. A routine that missed and runs a few instructions a frame — a fade
      # that is not fading — has a busiest part too, and making a `func` of it buys nothing.
      WORTH_NAMING = 5.0
      WORTH_A_FRAME = 1.0

      # At most this many parts of one routine, the busiest first.
      MOST_PARTS = 3

      module_function

      # The hints for +rom+'s routines that missed the quick memory, from +profile+ — busiest
      # first. Empty for a build that missed nothing, or a run that spent no time in what missed.
      def of(profile, rom)
        built = rom.built
        # A part's share of the frame is counted against the whole of each frame, asleep or not:
        # against only the time the console was awake, a game that sleeps most of each frame
        # would make a few instructions look like most of it.
        frame = profile.frames * profile.cycles_per_frame
        return [] if frame.zero?

        built.missed_routine_parts.flat_map do |routine, parts|
          span = built.routines[routine] or next []
          total = time_in(profile, span)
          next [] if total.zero?

          busiest_parts(profile, built, routine, parts, total, frame)
        end.sort_by { |hint| -hint.frame_share }
      end

      # The parts of one routine worth naming: the one holding the most of its time that fits
      # (or, where none fits, the most of all), then the same again among the parts that do not
      # overlap it. Where two hold the same time, the smaller — a block and the one statement it
      # holds are the same time, and the statement is what to cut out.
      def busiest_parts(profile, built, routine, parts, total, frame)
        # Each part with its time and the room a `func` that busy could have — worked out once,
        # so the part picked because it fits is the part said to fit.
        timed = parts.map { |part| [part, time_in(profile, part[:at])] }
                     .select { |_, time| 100.0 * time / total >= WORTH_NAMING && 100.0 * time / frame >= WORTH_A_FRAME }
                     .map { |part, time| [part, time, room_for(profile, built, time, routine)] }
        chosen = []
        MOST_PARTS.times do
          free = timed.reject { |part, _, _| chosen.any? { |taken, _, _| taken[:at].overlap?(part[:at]) } }
          break if free.empty?

          fitting = free.select { |part, _, room| part[:at].size <= room }
          chosen << (fitting.empty? ? free : fitting).max_by { |part, time, _| [time, -part[:at].size] }
        end
        chosen.map do |part, time, room|
          Hint.new(routine: routine, source: part[:source], share: (100.0 * time / total).round(1),
                   frame_share: (100.0 * time / frame).round(1), bytes: part[:at].size,
                   fits: part[:at].size <= room, room: room)
        end
      end

      # How long the console spent running code in +span+, in cycles.
      def time_in(profile, span)
        profile.cycles.sum { |at, spent| span.cover?(at) ? spent : 0 }
      end


      # The bytes a `func` that spends +time+ in +routine+ could have: what is spare, every
      # routine kept for the whole game that the run spent less time in — and, for a scene's own
      # routine in a game whose scenes each keep their own (see Cartridge::BuildRecord::SceneSets),
      # the room that scene's set leaves in the place the sets share, and every routine in its
      # set the run spent less time in. Other scenes' sets are never in at the same moment, so
      # nothing of theirs is in the way.
      def room_for(profile, built, time, routine)
        placement = built.placement
        given_up = placement.funcs.sum do |name|
          span = built.routines[name]
          span && time_in(profile, span) < time ? placement.sizes.fetch(name, 0) : 0
        end
        placement.free_bytes + given_up + room_in_scene_set(profile, built, time, routine)
      end

      def room_in_scene_set(profile, built, time, routine)
        sets = built.scene_sets or return 0
        number = sets.scenes[routine.to_s.delete_prefix("_scene_").to_sym] or return 0

        own = sets.routines.fetch(number, {})
        biggest = sets.routines.values.map { |set| set.values.sum(&:size) }.max.to_i
        less_busy = own.values.sum { |span| time_in(profile, span) < time ? span.size : 0 }
        biggest - own.values.sum(&:size) + less_busy
      end
    end
  end
end
