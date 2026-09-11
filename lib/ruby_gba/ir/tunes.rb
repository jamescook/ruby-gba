# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH TUNES A PROGRAM PLAYS, and what they take from the mixer — worked out here, once,
    # for every backend.
    #
    # It lives in one place because the answer is a promise the backends make to each other. A
    # song part that plays a recording keeps a voice of the mixer for itself, and the game's own
    # sounds get the voices that are left. Counted two ways, the interpreter would keep a sound
    # the console drops, and only in the one busy moment that fills the mixer.
    module Tunes
      module_function

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
        song.voices.flat_map do |part|
          [part[:instrument], *part[:events].map { |event| event[2] }]
        end.compact.uniq
      end

      # How many of a song's parts play a recording rather than a square wave.
      def recorded_parts(song)
        song.voices.count { |part| part[:instrument] }
      end

      # The most recorded parts any one played tune has.
      def most_recorded_parts(program)
        played(program).map { |song| recorded_parts(song) }.max || 0
      end

      # How many of the mixer's voices the music keeps: as many as the most any one played tune
      # has recorded parts, since one tune plays at a time. More than the mixer has cannot be
      # kept by any backend, so none of them is asked to — the build refuses such a song first
      # (Guardrails::Checks::SongTooManyParts), and this is only the backstop behind that.
      def mixer_voices(program)
        wanted = most_recorded_parts(program)
        return wanted if wanted <= Sound::MIXER_VOICES

        raise ArgumentError, "a song has #{wanted} parts that play a recording, and the mixer has " \
                             "#{Sound::MIXER_VOICES} voices"
      end

      # The played song with the most recorded parts — the one that decides how many voices the
      # music keeps — or nil when no played song has any.
      def keeps_the_most(program)
        played(program).select { |song| recorded_parts(song).positive? }.max_by { |song| recorded_parts(song) }
      end

      # The frame a song goes back to at its end: 0, unless it has a loop point.
      def loop_frame(song) = song.loop_frame || 0

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

        song.voices.map { |part| pass(part[:events], from) }
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

      def sounding?(event) = !event.nil? && event[1].positive?
    end
  end
end
