# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH TUNES A PROGRAM PLAYS, and how each part of one plays — worked out here, once, for
    # every backend.
    #
    # It lives in one place because the answer is a promise the backends make to each other.
    # Counted two ways, the interpreter would play a note the console does not, and only in the
    # one moment that decides it — the end of a song, a part with no room to sound.
    module Tunes
      # HOW LOUD THE MUSIC PLAYS RIGHT NOW, as a variable the game writes and the player reads
      # at the start of each frame — the same arrangement as the tune it names. It runs 0 to
      # FULL_LEVEL, and a part sounds at its written volume times that, over FULL_LEVEL. A
      # program that never says `music_volume` has no such variable, and plays every part at
      # its written volume with nothing worked out at all.
      #
      # Sixteen steps and not a hundred because a part's written volume has sixteen (0..15), so
      # a finer level would only round to the same volume. FULL_LEVEL being a power of two is
      # what lets #scaled_volume divide by it with a shift.
      LEVEL = :__music_level
      FULL_LEVEL = 16
      LEVEL_SHIFT = 4 # FULL_LEVEL is 1 << this

      # The loudness a recorded part's voice plays at when its written volume is 15. A mixer
      # voice's loudness runs 0 to this, where a console voice's runs 0 to 15.
      MIX_FULL = 64

      module_function

      # A written volume (0..15) — or a mixer voice's loudness — at +level+: multiplied and shifted
      # back down, so it is whole numbers on every backend and never rounds up past what was
      # written.
      def scaled_volume(volume, level) = (volume * level) >> LEVEL_SHIFT

      # A part's written volume, 0..15 like the console voices', as a mixer voice's loudness.
      def mix_loudness(volume) = (volume * MIX_FULL / 15.0).round

      # The songs the program can play, in the order they are declared: every song it names with
      # `play_song`, and every song in a list it picks from by number. A song that is written and
      # never played takes nothing.
      def played(program)
        names = program.walk.filter_map { |node| node.name if node.kind == :play_song }
        names += lists_played(program).values.flatten
        program.walk.select { |node| node.kind == :song && names.include?(node.name) }
      end

      # Each song list the program picks from by number, with its songs in order.
      def lists_played(program)
        picked = program.walk.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
        program.walk.select { |node| node.kind == :song_list && picked.include?(node.name) }
               .to_h { |node| [node.name, node.songs] }
      end

      # Every instrument a song names — for its parts, and for any note that names its own.
      def instruments(song)
        soundings(song).map(&:name).uniq
      end

      # WHAT ONE NOTE SOUNDS: the recording it plays, and the envelope that shapes how it starts
      # and ends. The two travel together because they are one thing to a sounding voice, and
      # keeping them together is what makes an envelope free per note: two notes on the same
      # recording shaped differently are two of these, each gets its own entry in the score's
      # table of recordings, and a note names an entry by the number it already carried.
      #
      # A nil envelope is "whatever the recording itself was declared with", which only the
      # backend knows, since it is the one holding the declarations.
      Sounding = Data.define(:name, :envelope)

      # Every sounding a song asks for. A note's own instrument and envelope win over the part's,
      # and the part's own pairing is here too, for a part whose notes all say nothing.
      def soundings(song)
        song.voices.flat_map do |part|
          next [] unless part.instrument

          part.events.map do |event|
            Sounding.new(name: event[2] || part.instrument, envelope: event[4] || part.envelope)
          end.push(Sounding.new(name: part.instrument, envelope: part.envelope))
        end.uniq
      end

      # WHICH OF THE CONSOLE'S VOICES A PART PLAYS ON, read off the part itself. One reader, so
      # no backend and no check can decide it differently — that is the same reason this whole
      # module exists.
      #
      # A part names its voice by what it SOUNDS LIKE: an instrument it plays, a waveform, or
      # the hiss. Naming none of those is the square wave, which is what a part was before any
      # of the others existed and is still what most parts are.
      def part_kind(part)
        return :recorded if part.instrument
        return :wave if part.wave
        return :noise if part.noise

        :square
      end

      # How many of a song's parts play on each of the console's voices.
      def parts_on(song, kind)
        song.voices.count { |part| part_kind(part) == kind }
      end

      # How many of a song's parts play a recording rather than one of the console's own voices.
      def recorded_parts(song) = parts_on(song, :recorded)

      # The most recorded parts any one played tune has — how many parts the player has to be
      # ready to find a voice for at once, since one tune plays at a time.
      def most_recorded_parts(program)
        played(program).map { |song| recorded_parts(song) }.max || 0
      end

      # The frame a song goes back to at its end: 0, unless it has a loop point.
      def loop_frame(song) = song.loop_frame || 0

      # WHO SOUNDS ON A VOICE TWO PLAYERS WANT AT ONCE — the song and a sound effect, or two
      # effects — as one number each, so a single comparison settles it on every backend.
      #
      # The higher priority takes the voice. A tie goes to a sound effect over the song, and
      # between two effects to the one declared first: the priority sits in the top half of the
      # number and the order in the bottom half, the song's bottom half 0 and the first effect's
      # the largest. A note takes a voice whose holder's rank is no higher than its own, so a
      # player's next note always takes back the voice its last one held — and a voice nobody
      # holds is rank 0, which every note takes.
      #
      # The bottom half tells the two kinds of holder apart as well: it is 0 for the song and
      # never 0 for an effect, which is how a song that stops knows to leave an effect's voice
      # alone.
      RANK_SHIFT = 16
      ORDER_MASK = (1 << RANK_SHIFT) - 1

      def song_rank(song) = (song.priority || 0) << RANK_SHIFT

      # +order+ counts the program's sound effects from 0, in the order they were declared.
      def effect_rank(song, order) = song_rank(song) | (ORDER_MASK - order)

      # THE PRIORITY A RANK CARRIES, without the order under it — what decides between two sound
      # effects of one GROUP (a song node's +group+), which play one at a time. Asked for while
      # another of its group is sounding or already asked for, an effect of at least that one's
      # priority stops it and starts in its place, a tie going to the one asked for; one of lower
      # priority is not played at all. An effect with no group plays alongside any other.
      def priority_of(rank) = rank >> RANK_SHIFT

      # Every sound effect the program declares, in order: the songs of each effect list.
      def effects(program)
        program.walk.select { |node| node.kind == :sound_effect_list }.flat_map(&:effects)
      end

      # ...and their song nodes, with every song the program plays: all it can sound.
      def played_and_effects(program)
        names = effects(program)
        played(program) + program.walk.select { |node| node.kind == :song && names.include?(node.name) }
      end

      # THE ORDER A FRAME PLAYS THE SOUND EFFECTS IN: highest rank first, as [name, rank] — given
      # the effects' song nodes in the order they were declared. Played in this order, with the
      # song's parts at their own rank's place among them, whoever writes a voice first on a
      # frame is whoever keeps it.
      def effects_by_rank(songs)
        songs.each_with_index.map { |song, order| [song.name, effect_rank(song, order)] }
             .sort_by { |_, rank| -rank }
      end

      # EACH PART'S NOTES THE FIRST TIME ROUND, AND EVERY TIME AFTER.
      #
      # A song that loops from a point plays what comes before it once: at its end the song
      # goes back to the loop frame and every part carries on from there. What makes that more
      # than moving a place in each list is what a part is DOING at the loop frame. The first
      # time round it gets there from the notes before; every time after, it gets there from
      # the end of the song, still sounding whatever it ended on. So each part is put into the
      # state the loop frame wants:
      #
      #   * a note that starts right there already does it;
      #   * a part silent there, and silent at the end, needs nothing;
      #   * a part silent there but still sounding at the end gets a rest there — which, the
      #     first time round, silences a part that is already silent, and so changes nothing;
      #   * a part holding a note across the loop frame sounds that note again there, every
      #     time AFTER the first. Not the first time: the note is already sounding then, and
      #     striking it again would be heard. So those parts alone get a list of their own for
      #     the later passes, starting with the held note. Unless the song ENDS on that same
      #     note — then it is still sounding when the song comes round, and simply carries on.
      #
      # A song that loops from its start is the same rule with nothing before the loop frame, so
      # all it can ever need is the rest — which is also what stops a part that comes in late
      # from ringing on into the first frames of the song each time round.
      #
      # +first+ is the part's events the first time; +again+ is every time after, and is the
      # tail of +first+ unless the part holds a note across the loop frame.
      Pass = Data.define(:first, :again)

      def passes(song)
        from = loop_frame(song)
        if from.positive? && from >= song.total_frames
          raise ArgumentError, "song #{song.name.inspect} loops from frame #{from}, and is #{song.total_frames} frames long"
        end

        song.voices.map { |part| pass(part.events, from) }
      end

      def pass(events, from)
        split = events.index { |event| event.first >= from } || events.size
        before = events.first(split)
        after = events.drop(split)
        return Pass.new(events, after) if after.first&.first == from

        held = before.last
        ending = events.last
        unless sounding?(held)
          return Pass.new(events, after) unless sounding?(ending)

          first = before + [[from, 0]] + after
          return Pass.new(first, first.drop(split))
        end
        return Pass.new(events, after) if ending.drop(1) == held.drop(1)

        Pass.new(events, [[from, *held.drop(1)]] + after)
      end

      # Does anything sound once the song has come round? A part does if a note in its later
      # passes does — which counts a note held across the loop frame and sounded again there —
      # or if the song ends on a note, which then carries on into the repeat.
      def repeat_sounds?(song)
        song.voices.zip(passes(song)).any? do |part, pass|
          sounding?(part.events.last) || pass.again.any? { |event| sounding?(event) }
        end
      end

      def sounding?(event) = !event.nil? && event[1].positive?
    end
  end
end
