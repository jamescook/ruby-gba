# frozen_string_literal: true

require "tmpdir"
require "json"

module RubyGBA
  # WHERE A GAME'S FRAMES ACTUALLY WENT, measured by running it.
  #
  # This runs the finished cartridge on the emulator and writes down which instruction the
  # console was executing, over and over, then puts those addresses back against the names of
  # the routines the author wrote. Nothing is predicted and nothing is modelled: the numbers
  # are counts of what happened.
  #
  # THE TWO HALVES IT NEEDS come from different places and neither can supply the other. The
  # emulator knows where the console was and nothing about the program; the build knows where
  # every routine ended up and nothing about what ran. A routine kept in the console's quick
  # memory is why the second half cannot be recovered from the cartridge afterwards — it was
  # copied there when the game booted and runs nowhere near where it sits in the ROM.
  #
  # WHAT IS NOT IN ANY ROUTINE gets a line of its own rather than being dropped or shared out.
  # It is mostly the console's own code: the routine it runs to divide, and the sleep at the
  # end of a frame. A profiler that quietly loses a fifth of a frame is worse than one that
  # says which fifth.
  class Profiler
    # How many frames to run before measuring, so a game is past its boot and into its loop.
    # A profile of a title screen is a profile of the wrong thing.
    SETTLE = 20

    # How many frames to measure over. Long enough that a game running at a third of the rate
    # still has plenty of finished frames to count, short enough to stay quick.
    FRAMES = 60

    # One routine's share of the run. +where+ is the memory it ran from, which an author never
    # chose and often wants to know: the same routine is about two and a third times faster in
    # the console's quick memory than in the cartridge.
    Line = Data.define(:name, :label, :samples, :share, :where)

    # A finished profile. +unattributed+ is the share that ran outside every routine the build
    # knows about.
    Result = Data.define(:frames, :samples, :fps, :idle_share, :lines, :unattributed, :keys) do
      def dropping_frames? = fps < 59.5

      def to_h
        { frames: frames, samples: samples, fps: fps, idle_share: idle_share,
          keys: keys.map(&:to_s), unattributed: unattributed,
          routines: lines.map do |line|
            { name: line.name.to_s, label: line.label, samples: line.samples,
              share: line.share, where: line.where.to_s }
          end }
      end
    end

    # Run +rom+ and report where its frames went. +keys+ are held for the settling and the
    # measured frames alike, because a game costs what the player makes it cost and a reading
    # with nothing held is a reading of a game standing still.
    def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
      routines = rom.built.routines
      held = Array(keys)

      profile = in_temp_rom(rom) do |path|
        probe = Emulator.probe(path)
        begin
          probe.profile(frames: frames, settle: settle, keys: held)
        ensure
          probe.close
        end
      end

      build_result(profile, routines, held)
    end

    def self.build_result(profile, routines, held)
      tally, outside = attribute(profile.pc, routines)
      total = profile.samples

      lines = tally.sort_by { |_, seen| -seen }.map do |name, seen|
        Line.new(name: name, label: PlainWords.routine(name), samples: seen,
                 share: share(seen, total), where: where_of(routines[name]))
      end
      lines += outside.sort_by { |_, seen| -seen }.map do |region, seen|
        Line.new(name: region, label: OUTSIDE.fetch(region), samples: seen,
                 share: share(seen, total), where: region)
      end

      Result.new(frames: profile.frames, samples: total, fps: profile.frames_per_second,
                 idle_share: profile.idle_share.round(4), lines: lines,
                 unattributed: share(outside.sum { |_, seen| seen }, total), keys: held)
    end

    # WHAT RAN THAT IS NOT A ROUTINE THE AUTHOR WROTE, named by where it ran rather than
    # lumped together, because the difference is the whole use of the line. Code in the
    # console's own memory is the BIOS — which on this machine means the divide routine
    # almost every time, and that is worth knowing, since a hot divide is something an
    # author can do about (a table, or a different sum). "Somewhere else" is neither, and
    # if it is ever more than a rounding error something is wrong with the routine map.
    OUTSIDE = { bios: "the console's own code (mostly dividing)",
                unmapped: "code with no routine recorded for it" }.freeze

    # Put each sampled address back against the routine whose span covers it. Routines never
    # overlap, so the first match is the only one. Returns the routines and, separately, what
    # fell outside them grouped by the memory it ran in.
    def self.attribute(counts, routines)
      spans = routines.sort_by { |_, span| span.begin }
      tally = Hash.new(0)
      outside = Hash.new(0)
      counts.each do |address, seen|
        hit = spans.find { |_, span| span.cover?(address) }
        if hit
          tally[hit.first] += seen
        else
          outside[address < 0x0100_0000 ? :bios : :unmapped] += seen
        end
      end
      [tally, outside]
    end

    def self.share(part, total) = total.zero? ? 0.0 : (100.0 * part / total).round(1)

    # Which memory a routine ran from, worked out from the address it ran at.
    def self.where_of(span)
      return :unknown if span.nil?

      (span.begin & 0xFF00_0000) == Constants::IWRAM_START ? :quick_memory : :cartridge
    end

    def self.in_temp_rom(rom)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "profile.gba")
        rom.write(path)
        return yield(path)
      end
    end

    # Print a measured profile the way `rom.explain` prints an estimated one — the dearest
    # line first, because that is the one worth looking at.
    def self.render(result, out: $stdout)
      printer = IR::Printer.for(out)
      printer.puts("where your frames went, measured over #{result.frames} frames#{held_note(result.keys)}")
      printer.puts("")
      printer.puts("  #{result.fps} frames a second#{dropped_note(result)}")
      printer.puts("  #{(result.idle_share * 100).round(1)}% of each frame spare")
      printer.puts("")

      result.lines.each { |line| printer.cost_line(label_for(line), "#{line.share}%") }
    end

    # A routine's line says which memory it ran from, because that is worth about two and a
    # third times its speed and an author never chose it. What is not a routine says nothing —
    # its own name already says where it was.
    def self.label_for(line)
      return line.label if OUTSIDE.key?(line.name)

      "#{line.label} — #{words_for(line.where)}"
    end

    def self.words_for(where)
      { quick_memory: "quick memory", cartridge: "cartridge" }.fetch(where, "somewhere else")
    end

    def self.held_note(keys) = keys.empty? ? "" : ", holding #{keys.map(&:to_s).join(' + ').upcase}"

    def self.dropped_note(result)
      result.dropping_frames? ? " — the game is not finishing its work in every frame" : ""
    end
  end
end
