# frozen_string_literal: true

require "zlib"

module RubyGBA
  module Diagnostics
    class Playthrough
      # THE PRESSES OF A PLAYTHROUGH, WRITTEN DOWN: which buttons were down on each frame, and
      # the frame each named moment fell on.
      #
      # A script says what to do; a tape says what was done. The difference matters the moment
      # a script watches the game: "walk right until the door" is as many frames as THIS game
      # took to reach the door, and the tape holds that number. So a tape is the same presses
      # on the same frames whatever it is played on — which is what lets two cartridges be
      # given exactly the same game to play, and their pictures laid side by side.
      #
      #   tape = walk.play(cartridge).tape
      #   tape.write("walk.tape")
      #   Tape.read("walk.tape").play(another_cartridge) { |moment, game| ... }
      #
      # IT IS PLAIN TEXT, a line for each stretch of frames with the same buttons down, so a
      # person can read one and a change to one shows as a change to a few lines:
      #
      #   ruby-gba tape 1
      #   recorded on: HERO 0x5C0FFEE5
      #   starts from: power-on
      #
      #   10 -
      #   1 down
      #   1 -
      #   20 right up
      #   moment walked
      #
      # Three lines of heading, always those three and in that order. Then a count and the
      # buttons down for that many frames, `-` for none; and a moment on a line of its own,
      # naming the frame the line before it ended on.
      #
      # WHAT IT WAS RECORDED ON IS FOR A PERSON. The cartridge's title and a checksum of its
      # bytes say which game and which build the tape came from. Nothing checks them against
      # the cartridge it is played on: playing a tape on a different cartridge is the point.
      #
      # WHERE IT STARTED IS HELD TO. The third line says `power-on`, or `a save` for a
      # cartridge that held one when the console was switched on. The same presses from
      # power-on are a different game, so a tape recorded from a save is played from one.
      #
      # +steps+ are the lines in order — each a Hold or a Moment, the same steps a script is
      # made of, so a tape is played by the same playing a script is.
      Tape = Data.define(:title, :checksum, :starts_from, :steps)

      class Tape
        # What a tape's file opens with: what it is, and which way of writing one this is.
        FIRST_LINE = "ruby-gba tape 1"

        # How a stretch of frames with no button down is written.
        NOTHING_DOWN = "-"

        # Where a playthrough starts, as the tape says it: the console switched on with a
        # cartridge nobody has played, or with one holding a save. A save is said with a
        # checksum of its bytes, like the cartridge's, for a person to tell which save the
        # tape goes with. The save itself is not in the tape: a tape is the presses, and
        # played on another cartridge it wants that one's own.
        POWER_ON = "power-on"
        A_SAVE = /\Aa save 0x\h{8}\z/

        # The tape of +steps+ played on +cartridge+. What it says it was recorded on is the
        # title in the cartridge's own header and a checksum of every byte of it. +save+ is
        # the save memory the cartridge held when the console was switched on, or nil.
        def self.recorded_on(cartridge, steps, save:)
          title, checksum = title_and_checksum_of(cartridge)
          starts_from = save ? format("a save 0x%08X", Zlib.crc32(save.to_sav)) : POWER_ON
          new(title: title, checksum: checksum, starts_from: starts_from, steps: steps)
        end

        # What a person tells one cartridge from another by: the title in its own heading,
        # and a checksum of every byte of it, which says which build of that game it is.
        def self.title_and_checksum_of(cartridge)
          header_title = cartridge.buffer.byteslice(Cartridge::Header::HEADER_TITLE, Cartridge::ROM::TITLE_LENGTH)
          [printable(header_title), Zlib.crc32(cartridge.buffer)]
        end

        # Those two as they are written for a person, on a tape and in a report: `HERO 0x5C0FFEE5`.
        def self.label(title, checksum) = "#{title} #{format('0x%08X', checksum)}"
        def self.label_of(cartridge) = label(*title_and_checksum_of(cartridge))

        # The cartridge this tape was recorded on, written the same way.
        def recorded_on_label = Tape.label(title, checksum)

        # A header's title as a line a person can read. The header holds twelve bytes, padded
        # with noughts, and a cartridge somebody else made can hold anything in them — so a
        # byte that is not a printable letter is written as `?`.
        def self.printable(header_title)
          header_title.b.delete("\0").gsub(/[^\x20-\x7E]/n, "?").strip.encode("UTF-8")
        end

        # The tape in the file at +path+.
        def self.read(path)
          raise ArgumentError, "There is no tape file at #{path}. Give the path of a file that `Tape#write` wrote." unless File.file?(path)

          parse(File.read(path), from: path)
        end

        # The tape +text+ is. +from+ says where the text came from, for an error to name.
        def self.parse(text, from: "This text") = Reader.new(text, from).read_tape

        # A tape holds nothing but names and numbers, and is made so that every core can read
        # it: it can be kept in a constant, and handed from one Ractor to another.
        def initialize(title:, checksum:, starts_from:, steps:)
          super(**Ractor.make_shareable({ title: title.dup, checksum: checksum, starts_from: starts_from.dup, steps: steps.dup }))
        end

        # Play the tape on +cartridge+, exactly as a playthrough plays its script: the block is
        # handed each moment's name and the running cartridge, and what comes back is the same.
        #
        # A tape recorded from a save is played from one: from power-on it would be the same
        # presses on a different game.
        def play(cartridge, save: nil, pictures_in: nil, &at_each_moment)
          refuse_missing_save!(save)
          Playing.play(title, steps, cartridge, save: save, pictures_in: pictures_in, &at_each_moment)
        end

        # Play the tape on +first+ and on +second+ together, comparing the two pictures after
        # every frame. +settings+ say how alike they have to be, and which stretches of the
        # tape are not looked at (see Comparison).
        #
        # Both start from power-on, so a tape recorded from a save cannot be compared.
        def compare(first, second, **settings)
          refuse_comparing_from_save!
          Comparison.new(first, second, moments.keys, **settings).run(self)
        end

        def recorded_from_save? = starts_from != POWER_ON

        private def refuse_missing_save!(save)
          return unless recorded_from_save? && save.nil?

          raise ArgumentError, "This tape was recorded on a cartridge that started from a save. From power-on, the same " \
                               "presses play a different game. Give the save to start from: `tape.play(cartridge, save: ...)`."
        end

        private def refuse_comparing_from_save!
          return unless recorded_from_save?

          raise ArgumentError, "This tape was recorded on a cartridge that started from a save. A comparison starts both " \
                               "cartridges from power-on, so it cannot play this tape. Record the tape from power-on."
        end

        # THE TAPE AS FAR AS +frame+ AND NO FURTHER: the same presses, ending on that frame. It
        # is how a moment part way through is got back to — play this, and the cartridge is
        # on that frame. A hold the frame falls inside is cut short there. A moment is kept
        # when the frame it names was played, the last frame included. A frame past the end
        # of the tape is the whole tape.
        def up_to(frame)
          refuse_frame_below_one!(frame)
          with(steps: steps_up_to(frame))
        end

        private def refuse_frame_below_one!(frame)
          return if frame.is_a?(Integer) && frame >= 1

          raise ArgumentError, "A tape was asked for its frames up to #{frame.inspect}. Frames are counted from 1, " \
                               "so give a whole number, 1 or more."
        end

        # A moment after a hold that was cut short named a later frame than the cut, so
        # nothing after the cut is kept. One after a hold that ended on the frame names that
        # frame, and is.
        private def steps_up_to(frame)
          played = 0
          steps.each_with_object([]) do |step, kept|
            left = frame - played
            return kept if left.zero? && step.frames.positive?
            return kept << step.with(frames: left) if step.frames > left

            kept << step
            played += step.frames
          end
        end

        # A run of frames with the same buttons down: +frames+ is the range of them,
        # counted from 1, and +buttons+ what was down.
        Stretch = Data.define(:frames, :buttons)

        # WHAT WAS DOWN ON EACH OF THE FRAMES +frames+, a range of frame numbers: one
        # Stretch for each run of them with the same buttons down, in order. A moment
        # between two lines of the same buttons does not split a run, since a moment is
        # no frames long; and a run that reaches outside the range is cut to it.
        def presses_within(frames)
          ends_on = 0
          steps.each_with_object([]) do |step, runs|
            next if step.frames.zero?

            starts_on = ends_on + 1
            ends_on += step.frames
            inside = [starts_on, frames.begin].max..[ends_on, frames.end].min
            next if inside.none?

            longer = runs.last&.buttons == step.buttons
            longer ? runs[-1] = runs.last.with(frames: runs.last.frames.begin..inside.end) : runs << Stretch.new(frames: inside, buttons: step.buttons)
          end
        end

        # How many frames the tape plays.
        def frames = steps.sum(&:frames)

        # The frame each named moment falls on, counted from 1.
        def moments
          played = 0
          steps.each_with_object({}) do |step, found|
            played += step.frames
            step.names.each { |name| found[name] = played }
          end
        end

        # The tape as the text of a file.
        def to_s
          heading = [FIRST_LINE, "recorded on: #{recorded_on_label}", "starts from: #{starts_from}", ""]
          (heading + steps.map(&:tape_line)).join("\n") << "\n"
        end

        # Write the tape to +path+, which is handed back.
        def write(path)
          File.write(path, to_s)
          path
        end

        # A TAPE BEING MADE, a line at a time — by a playing as it plays, and by a file as it
        # is read. Frames with the same buttons down run on from the ones before, so a wait
        # that watched the game for ninety frames is one line of ninety and not ninety of one;
        # and the buttons of a line are in the console's own order, so the same presses are
        # the same tape however they were written.
        class Taping
          attr_reader :steps, :frames

          def initialize
            @steps = []
            @frames = 0
          end

          def hold(buttons, frames)
            held = Playthrough.in_console_order(buttons)
            longer = @steps.last&.extended_by(held, frames)
            longer ? @steps[-1] = longer : @steps << Hold.new(buttons: held, frames: frames)
            @frames += frames
          end

          def moment(name) = @steps << Moment.new(name: name)

          # Every moment named so far.
          def names = @steps.flat_map(&:names)
        end

        # ONE READING OF A TAPE'S TEXT. A tape is written by a program and read back by one, but
        # it is also a file a person can open and change, so every line that cannot be read is
        # an error saying which line, what is on it, and what a line there has to look like.
        class Reader
          def initialize(text, from)
            @lines = text.lines.map(&:strip)
            @from = from
            @taping = Taping.new
          end

          def read_tape
            refuse_unknown_first_line!
            title, checksum = read_recorded_on
            starts_from = read_starts_from
            @lines.each_with_index.drop(HEADING_LINES).each { |line, at| read_step(line, at + 1) }
            Tape.new(title: title, checksum: checksum, starts_from: starts_from, steps: @taping.steps)
          end

          private

          HEADING_LINES = 3
          private_constant :HEADING_LINES

          def refuse_unknown_first_line!
            return if @lines.first == FIRST_LINE

            found = @lines.empty? ? "The file is empty." : "Line 1 is #{@lines.first.inspect}."
            raise ArgumentError, "#{@from} is not a tape. A tape starts with the line `#{FIRST_LINE}`. #{found}"
          end

          def read_recorded_on
            said = @lines[1].to_s.match(/\Arecorded on: (.*) 0x(\h{8})\z/) or
              raise_unreadable_line!(2, "Line 2 must say what the tape was recorded on, like `recorded on: HERO 0x5C0FFEE5`.")
            [said[1], said[2].to_i(16)]
          end

          def read_starts_from
            said = @lines[2].to_s.delete_prefix("starts from: ")
            return said if @lines[2] != said && (said == POWER_ON || A_SAVE.match?(said))

            raise_unreadable_line!(3, "Line 3 must say where the playthrough starts: `starts from: #{POWER_ON}`, " \
                                      "or `starts from: a save 0x5C0FFEE5` with the checksum of the save.")
          end

          def read_step(line, number)
            return if line.empty? || line.start_with?("#")

            first, *rest = line.split
            return read_moment(rest.join(" "), number) if first == "moment"

            unless first.match?(/\A[1-9]\d*\z/)
              raise_unreadable_line!(number, "A line must start with how many frames it lasts, as a whole number, 1 or more.")
            end
            @taping.hold(buttons_named(rest, number), first.to_i)
          end

          def buttons_named(words, number)
            raise_unreadable_line!(number, "After the count, name the buttons that are down, or write `#{NOTHING_DOWN}` for none.") if words.empty?
            return [] if words == [NOTHING_DOWN]

            if words.include?(NOTHING_DOWN)
              raise_unreadable_line!(number, "`#{NOTHING_DOWN}` means no button is down. Write `#{NOTHING_DOWN}` alone, or name the buttons.")
            end
            names = words.map(&:to_sym)
            unknown = names.find { |name| !IR::Buttons.known?(name) } or return names

            raise_unreadable_line!(number, "#{unknown.to_s.inspect} names a button the console does not have. " \
                                           "The buttons are #{IR::Buttons::NAMES.join(', ')}.")
          end

          # The rules are Moment's own, shared with a script; the words are a tape's.
          def read_moment(name, number)
            problem = Moment.problem_with(name.to_sym, named: @taping.names, any_frames: @taping.frames.positive?)
            return @taping.moment(name.to_sym) unless problem

            raise_unreadable_line!(number, format(MOMENT_PROBLEMS.fetch(problem), name: name))
          end

          MOMENT_PROBLEMS = {
            not_a_plain_name: "A moment needs a name made of letters, digits and underscores, like `moment at_the_door`.",
            before_any_frame: "A moment names the frame the line before it ended on. No line of frames comes before " \
                              "this one. Put the moment after a line of frames.",
            named_already: "The tape already has a moment named %<name>s. A name must mean one frame. " \
                           "Give this moment a different name.",
          }.freeze
          private_constant :MOMENT_PROBLEMS

          def raise_unreadable_line!(number, advice)
            raise ArgumentError, "#{@from} cannot be read at line #{number}: #{@lines[number - 1].to_s.inspect}. #{advice}"
          end
        end
      end
    end
  end
end
