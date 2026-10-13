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
      # +steps+ are the lines in order — each a Hold or a Moment, the same steps a script is
      # made of, so a tape is played by the same playing a script is.
      Tape = Data.define(:title, :checksum, :starts_from, :steps)

      class Tape
        # What a tape's file opens with: what it is, and which way of writing one this is.
        FIRST_LINE = "ruby-gba tape 1"

        # How a stretch of frames with no button down is written.
        NOTHING_DOWN = "-"

        # Where a playthrough starts, as the tape says it. Power-on is the one place there is.
        POWER_ON = "power-on"

        # The tape of +steps+ played on +cartridge+ from power-on. What it says it was recorded
        # on is the title in the cartridge's own header and a checksum of every byte of it.
        def self.recorded_on(cartridge, steps)
          header_title = cartridge.buffer.byteslice(Cartridge::Header::HEADER_TITLE, Cartridge::ROM::TITLE_LENGTH)
          new(title: printable(header_title), checksum: Zlib.crc32(cartridge.buffer), starts_from: POWER_ON, steps: steps)
        end

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
        def play(cartridge, &at_each_moment) = Playing.play(title, steps, cartridge, &at_each_moment)

        # Play the tape on +first+ and on +second+ together, comparing the two pictures after
        # every frame. +how_alike+ says how alike they have to be (see Comparison).
        def compare(first, second, **how_alike) = Comparison.new(first, second, **how_alike).run(self)

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
          heading = [FIRST_LINE, "recorded on: #{title} #{format('0x%08X', checksum)}", "starts from: #{starts_from}", ""]
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
            return POWER_ON if @lines[2] == "starts from: #{POWER_ON}"

            raise_unreadable_line!(3, "Line 3 must say where the playthrough starts: `starts from: #{POWER_ON}`.")
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
