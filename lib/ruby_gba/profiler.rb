# frozen_string_literal: true

require "tmpdir"
require "json"
require "zlib" # a save state carries the checksum of the cartridge it was taken from
require "stringio" # the throwaway first build of a measured one says nothing

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

    # How the measured moment was reached. A profile without this is not reproducible: the same
    # cartridge measured on its title screen and measured in its boss fight are different
    # numbers about different code, and nothing in the numbers themselves says which you have.
    Reached = Data.define(:how, :detail) do
      def to_s
        case how
        when :scene then "held in the #{detail.inspect} scene"
        when :state then "from the saved moment in #{File.basename(detail)}"
        else "as the game boots"
        end
      end

      def to_h = detail ? { how: how.to_s, detail: detail.to_s } : { how: how.to_s }
    end

    # WHETHER THE PICTURE HELD TOGETHER, on the frames that were looked at. +looked+ is how
    # many, +torn+ how many of those showed a seam, +worst+ the most rows one of them showed
    # before the game had finished them. nil where the screen cannot tear at all.
    Tear = Data.define(:looked, :torn, :worst) do
      def torn? = torn.positive?
    end

    # HOW MANY FRAMES TO LOOK AT FOR A TEAR, and why it is a handful rather than all of them.
    # Reading one costs a bus read per pixel — 38,400 of them — where the profiling itself
    # costs nothing per frame. And a tear is not a rare accident: it is a frame that does more
    # drawing than fits in the gap between frames, so a game that tears tears steadily. A few
    # frames answer it; sixty would only cost sixty times as much to say the same thing.
    TEAR_FRAMES = 6

    # A finished profile. +unattributed+ is the share that ran outside every routine the build
    # knows about.
    Result = Data.define(:frames, :samples, :fps, :idle_share, :lines, :unattributed, :keys,
                         :reached, :tearing) do
      def dropping_frames? = fps < 59.5

      # Instructions a frame — what the game actually does, where a share only says how that
      # work was divided up. A game asleep most of every frame can still have one routine at
      # 100 per cent of the little it runs.
      def samples_per_frame = frames.zero? ? 0.0 : samples / frames.to_f

      def to_h
        { frames: frames, samples: samples, fps: fps, idle_share: idle_share,
          keys: keys.map(&:to_s), unattributed: unattributed, reached: reached.to_h,
          tearing: tearing && { looked: tearing.looked, torn: tearing.torn, worst: tearing.worst },
          routines: lines.map do |line|
            { name: line.name.to_s, label: line.label, samples: line.samples,
              share: line.share, where: line.where.to_s }
          end }
      end
    end

    # Run +rom+ and report where its frames went. +keys+ are held for the settling and the
    # measured frames alike, because a game costs what the player makes it cost and a reading
    # with nothing held is a reading of a game standing still.
    # +tearing+ is off for the run the BUILD makes of itself to choose what goes in the quick
    # memory: that pass wants the routine counts and nothing else, and looking for a tear costs
    # a bus read per pixel, per frame, which is the dearest thing here by a wide margin.
    def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [], enter: nil, scene: nil, from: nil,
                 tearing: true)
      routines = rom.built.routines
      held = Array(keys)
      raise ArgumentError, "give `scene:` or `from:`, not both. A saved moment already says " \
                           "which scene the game was in." if from && scene
      enter ||= scene_state(rom, scene)
      reached = reached_by(scene, from)

      profile, tearing = in_temp_rom(rom) do |path|
        probe = Emulator.probe(path)
        begin
          measured =
            if from
              resumed_from(probe, from, path, frames, held)
            elsif enter
              pinned_to(probe, enter, frames, held)
            else
              plain_run(probe, frames, settle, held)
            end
          # Looked at AFTER the profiling, from wherever it left the game — so the frames
          # judged are the same frames that were measured, doing the same work.
          [measured, tearing && tearing_in(probe, rom.built.source_program, held)]
        ensure
          probe.close
        end
      end

      build_result(profile, routines, held, reached, tearing)
    end

    # DID THE PICTURE ACTUALLY TEAR — the question the build can only ask, not answer.
    #
    # The build says whether a game CAN tear, which is a fact about the screen it chose: a
    # game that draws straight into the one picture the display is reading can, and a
    # double-buffered or tiled game cannot, however slow it is. Whether one that can does is a
    # race between the display's row and the game's, and only running it settles that.
    def self.tearing_in(probe, program, held)
      return nil unless Tearing.measurable?(program)

      readings = TEAR_FRAMES.times.map do
        probe.step(1, keys: held)
        Tearing.read(probe)
      end
      torn = readings.select(&:torn?)
      Tear.new(looked: readings.length, torn: torn.length, worst: torn.map(&:rows).max || 0)
    end

    def self.reached_by(scene, from)
      return Reached.new(how: :scene, detail: scene.to_sym) if scene
      return Reached.new(how: :state, detail: from) if from

      Reached.new(how: :boot, detail: nil)
    end

    # MEASURE A MOMENT SOMEBODY PLAYED TO, which is the only fully general answer.
    #
    # Booting into a scene gives the routines that scene RUNS. It does not give the state that
    # makes the scene expensive: the boss scene with nothing spawned is not the boss fight. A
    # saved state carries both — the boss, its remaining health, and the twelve fireballs on
    # screen — and it is captured by playing to the moment once, in any emulator.
    #
    # THE CATCH, AND IT IS HANDLED RATHER THAN HOPED ABOUT. A state is a snapshot of addresses,
    # and every one belongs to the exact cartridge it came from. Rebuild the game — change one
    # number — and everything has moved, so the state's addresses now point at whatever took
    # their place. That still reads as numbers, so it measures rubbish quietly, which is worse
    # than not running at all.
    #
    # The emulator will not catch this for us: it refuses a state from a different GAME (it
    # compares the title in the cartridge header) and accepts one from a different BUILD of the
    # same game, which is the case that happens every time somebody edits a line. So the
    # cartridge's own checksum, which the state records, is compared here.
    #
    # A BUILD IS DETERMINISTIC, which is what keeps this from being a nuisance: building the
    # same source twice gives the same bytes, so simply re-running a build never costs anybody
    # their saved moments. Only a real change moves the addresses, and that is exactly when the
    # state has stopped meaning anything.
    def self.resumed_from(probe, state_path, rom_path, frames, held)
      check_state_matches!(probe, state_path, rom_path)
      probe.load_state(state_path)
      probe.profile(frames: frames, keys: held)
    end

    def self.check_state_matches!(probe, state_path, rom_path)
      raise ArgumentError, "there is no saved moment at #{state_path}." unless File.file?(state_path)

      said = probe.state_identity(state_path)
      raise ArgumentError, "#{File.basename(state_path)} is not a saved moment this can " \
                           "read." unless said

      ours = Zlib.crc32(File.binread(rom_path))
      return if said[:rom_crc32] == ours

      raise ArgumentError, <<~MSG.chomp
        #{File.basename(state_path)} was saved from a different build of this game, so it cannot be measured.

        A saved moment holds addresses, and this build put everything somewhere else. Reading it would give numbers about the wrong code.

        Play to the moment again on this build and save it again.
      MSG
    end

    def self.plain_run(probe, frames, settle, held)
      probe.profile(frames: frames, settle: settle, keys: held)
    end

    # Where a named scene's state lives and what value means it — so `scene: :playing` can hold
    # the game there. A friendly error for a name the game does not have, since the alternative
    # is silently measuring whatever screen it happened to boot to.
    def self.scene_state(rom, scene)
      return nil unless scene

      dispatch = Analyzer.scenes(rom.built.source_program)
      raise ArgumentError, "this game has no scenes, so there is no #{scene.inspect} to profile. " \
                           "To profile it as it boots, leave `scene:` out." unless dispatch

      value = dispatch[:scenes][scene.to_sym]
      unless value
        raise ArgumentError, "this game has no scene called #{scene.inspect}. Its scenes are: " \
                             "#{dispatch[:scenes].keys.map(&:inspect).join(', ')}."
      end

      address = rom.built.var_addresses[dispatch[:selector]]
      raise ArgumentError, "this game's scenes are not held in a variable this can reach." unless address

      { address: address, value: value }
    end

    # HOLD THE GAME IN ONE SCENE AND MEASURE THAT, without playing it there.
    #
    # A profile of a title screen is a profile of the wrong thing, and holding a button will
    # not get past one — a menu reads the press EDGE, so a held button is one press however
    # long it is held. But which scene a game is in is just a variable, and the build knows
    # where that variable lives. So it is written, and the next frame is the scene asked for.
    #
    # WRITING IT ONCE IS NOT ENOUGH, and finding that out is what this method is. A game left
    # to itself LEAVES the scene almost at once: put snake into its playing scene with nobody
    # holding a direction and the snake is dead within a few frames, so what gets measured is
    # the game-over screen under the playing scene's name. Measured on examples/snake_buffered.rb,
    # where every scene reported the same routines and the busiest one in the game — the
    # repaint — never appeared at all.
    #
    # So it is written again before every frame, and the game is held there. What that measures
    # is "the routines this scene runs", which is the question the placement is asking. It is
    # not a game anybody could play — a snake that dies and is forced back is nonsense as a
    # game — and it does not need to be.
    def self.pinned_to(probe, enter, frames, held)
      probe.step(BOOT_FRAMES, keys: held)
      address = enter.fetch(:address)
      value = enter.fetch(:value)
      probe.write32(address, value)
      probe.step(SETTLE, keys: held)

      frames.times.map do
        probe.write32(address, value)
        probe.profile(frames: 1, keys: held)
      end.reduce { |a, b| add_profiles(a, b) }
    end

    # Two runs' counts as one. Straight sums, since each is a count of the same things.
    def self.add_profiles(a, b)
      a.with(frames: a.frames + b.frames, samples: a.samples + b.samples,
             halted: a.halted + b.halted, elsewhere: a.elsewhere + b.elsewhere,
             finished: a.finished + b.finished,
             pc: a.pc.merge(b.pc) { |_, x, y| x + y })
    end

    # Frames to run before setting the scene, so the game is past its own start-up and the
    # variable exists to be written.
    BOOT_FRAMES = 8

    # MEASURE THE WHOLE GAME, one scene at a time, and answer what it spends its frames on.
    #
    # This is what lets the build measure rather than guess, with nobody having to play the
    # game first. A game keeps which screen it is on in a variable; the build knows where that
    # variable lives; so each scene is entered by writing it and then profiled.
    #
    # THE SHARES ARE COMBINED BY TAKING THE LARGEST, not by averaging. What is being decided
    # is which routines are worth the console's quick memory, and a routine that is most of
    # the frame in ONE scene has earned its place whatever it does in the others — a game is
    # only ever in one scene at a time, and the one that matters is the one that is busiest.
    # An average would rank a routine carrying a whole scene below one that idles in all of
    # them.
    #
    # A game with no scenes at all is measured as it boots, which is the whole of it.
    #
    # Answers instructions-a-frame per routine, which is what {RoutineProfile} keeps.
    def self.every_scene(rom, frames: FRAMES, keys: [])
      dispatch = Analyzer.scenes(rom.built.source_program)
      address = dispatch && rom.built.var_addresses[dispatch[:selector]]
      return work_in(run(rom, frames: frames, keys: keys, tearing: false)) unless address

      per_scene = dispatch[:scenes].map do |_name, value|
        work_in(run(rom, frames: frames, keys: keys, tearing: false,
                    enter: { address: address, value: value }))
      end
      per_scene.reduce(Hash.new(0)) do |busiest, scene|
        scene.each { |name, work| busiest[name] = [busiest[name], work].max }
        busiest
      end
    end

    # How many instructions a frame each routine ran, counted rather than shared out. Straight
    # off the sample counts, so a scene measured over a different number of frames than another
    # still gives a number the two can be compared on.
    def self.work_in(result)
      return {} if result.frames.zero?

      result.lines.reject { |line| OUTSIDE.key?(line.name) }
            .to_h { |line| [line.name, (line.samples.to_f / result.frames).round] }
    end

    def self.build_result(profile, routines, held, reached = Reached.new(how: :boot, detail: nil),
                          tearing = nil)
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
                 unattributed: share(outside.sum { |_, seen| seen }, total), keys: held,
                 reached: reached, tearing: tearing)
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
    def self.render(result, out: $stdout, rom: nil)
      printer = IR::Printer.for(out)
      # WHAT THE BUILD MADE COMES FIRST, and it is here rather than under a verb of its own
      # because the two halves answer one question between them. The build says a routine
      # missed the quick memory by four tenths of a kilobyte; the run says that routine is
      # most of the frame. Either alone sends a reader the wrong way.
      if rom
        BuildReport.render(rom, out: out)
        printer.puts("")
      end
      printer.puts("where your frames went, measured over #{result.frames} frames#{held_note(result.keys)}")
      # Which moment this is of, said out loud: the same cartridge measured on its title screen
      # and measured in its boss fight are different numbers about different code.
      printer.puts("  #{result.reached}")
      printer.puts("")
      printer.puts("  #{result.fps} frames a second#{dropped_note(result)}")
      printer.puts("  #{(result.idle_share * 100).round(1)}% of each frame spare")
      tearing_line(result.tearing, printer)
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

    # Said only where a tear could be looked for. A screen that cannot tear says nothing here,
    # because "we did not look" must never read as "nothing was wrong".
    def self.tearing_line(tear, printer)
      return if tear.nil?

      if tear.torn?
        printer.puts("  the picture tore on #{tear.torn} of the #{tear.looked} frames looked " \
                     "at — up to #{tear.worst} rows showed before the game had finished them",
                     severity: :bad)
      else
        printer.puts("  the picture held together on all #{tear.looked} frames looked at")
      end
    end

    def self.held_note(keys) = keys.empty? ? "" : ", holding #{keys.map(&:to_s).join(' + ').upcase}"

    def self.dropped_note(result)
      result.dropping_frames? ? " — the game is not finishing its work in every frame" : ""
    end
  end
end
