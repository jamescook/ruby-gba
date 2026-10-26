# frozen_string_literal: true

require "json"

module VBlank
  module Diagnostics
    # WHAT A GAME'S FRAMES WERE MEASURED TO SPEND, kept as a file so a later build can read it.
    #
    # The build has one decision it cannot measure its way to: which routines go in the console's
    # quick memory, where code runs about two and a third times faster. The choice is an INPUT to
    # the lowering, so it has to be made before the game it would run has ever run.
    #
    # The way out is to measure once and feed it back. Build the game, profile it, save what came
    # out; the next build reads that and keeps the routines the game really spends its time in.
    # You build twice, and the second build is right by measurement rather than by a model of
    # what the code might cost.
    #
    # IT IS KEYED BY ROUTINE NAME, which is what makes it survive a rebuild at all. Addresses all
    # move when a program changes; a name only changes when somebody renames it, and then the
    # profile says so instead of quietly pointing at nothing.
    class RoutineProfile
      # What a build gets when there is no profile to read: it answers "nothing measured" and
      # every caller falls back to the rule it keeps for that case.
      NONE = nil

      # HOW MANY INSTRUCTIONS A FRAME each routine was measured to run, and the game it was
      # measured on (for a message when the two no longer look like each other).
      #
      # A COUNT AND NOT A SHARE, and the difference decides real placements. A share is measured
      # against the other code that ran, so a game asleep nine tenths of every frame still has
      # some routine accounting for most of the little that did — an empty game loop reads as
      # 100 per cent of itself. What decides whether a routine is worth the console's quick
      # memory is how much work it actually does, and that is a count.
      attr_reader :work, :game, :measured_at, :busiest

      # THE SCENE WHOSE FRAMES DO THE MOST WORK, and the part of that work each routine did
      # there, in per cent — the figure `rom.profile` prints beside the routine for that scene.
      #
      # Kept beside the counts because the counts cannot answer "how much of a frame is this
      # routine". They are added up over every scene, so a routine that runs on all of them is
      # counted once for each: right for deciding what the quick memory is worth to it, and
      # wrong as a part of any one frame. The busiest scene is the one to ask about, since it
      # is the frame with the least room to lose. +scene+ is nil for a game with no scenes.
      Busiest = Data.define(:scene, :shares)

      # One routine's part of the busiest scene's work, in per cent, and which scene that was.
      Share = Data.define(:percent, :scene)

      # EACH SCENE'S OWN COUNTS, by the scene's name: instructions a frame of that scene ran in
      # each routine. Empty for a game with no scenes, and for a profile saved before these
      # were kept. The added-up counts rank a routine by what it is worth over the whole game;
      # these say what it is worth to any ONE frame, which is what a scene's own share of the
      # quick memory is chosen by (see GBA::QuickMemoryPlan).
      attr_reader :scenes

      # HOW MANY TIMES A FRAME READ OR WROTE EACH LIST, by the list's name, added up over the
      # scenes as the counts are. It is what keeping a list in the quick memory is worth, as the
      # counts are for a routine (see #worth_of_list). nil for a profile saved before these were
      # kept, which is different from one that measured every list at nothing. +scene_touches+
      # are each scene's own, by the scene's name, as #scenes are for the counts.
      attr_reader :touches, :scene_touches

      def initialize(work:, game: nil, measured_at: nil, busiest: nil, scenes: {}, touches: nil, scene_touches: {})
        @work = work
        @game = game
        @measured_at = measured_at
        @busiest = busiest
        @scenes = scenes
        @touches = touches
        @scene_touches = scene_touches
      end

      # Read a saved profile. Returns nil when there is no file — a missing profile is the
      # ordinary case on a first build, not an error.
      def self.read(path)
        return nil unless path && File.file?(path)

        data = JSON.parse(File.read(path))
        new(work: data.fetch("routines", {}).transform_keys(&:to_sym),
            game: data["game"], measured_at: data["measured_at"], busiest: busiest_from(data["busiest_scene"]),
            scenes: data.fetch("scenes", {}).to_h { |scene, counts| [scene.to_sym, counts.transform_keys(&:to_sym)] },
            touches: data["lists"]&.transform_keys(&:to_sym),
            scene_touches: data.fetch("scene_lists", {}).to_h { |scene, counts| [scene.to_sym, counts.transform_keys(&:to_sym)] })
      rescue JSON::ParserError => e
        raise ProfileError, "#{path} is not a profile this can read (#{e.message}). To fix this, " \
                            "measure the game again with `rom.profile` and save it."
      end

      # Build one from a measured run. What ran outside every routine — the console's own code —
      # is left out: it is real time and it is worth reporting, but it is not a routine and
      # nothing can be decided about where to put it.
      def self.from_result(result, game: nil)
        new(work: Profiler.work_in(result), game: game, measured_at: Time.now.utc.iso8601)
      end

      # ...and from what {Profiler.survey_scenes} answers, which is already instructions a frame
      # per routine, added up over every scene it runs in.
      def self.from_work(work, game: nil)
        new(work: work, game: game, measured_at: Time.now.utc.iso8601)
      end

      # ...and from the whole of what it answers: the counts, and the busiest scene's reading.
      def self.from_survey(survey, game: nil)
        new(work: survey.work, game: game, measured_at: Time.now.utc.iso8601, busiest: busiest_in(survey.scenes),
            scenes: survey.placement_readings.filter_map { |scene, reading| [scene, Profiler.work_in(reading)] if scene }.to_h,
            touches: Profiler.sum_touches_across_scenes(survey.scenes.values),
            scene_touches: survey.scenes.filter_map { |scene, reading| [scene, Profiler.touches_in(reading)] if scene }.to_h)
      end

      # The scene that ran the most instructions a frame, out of +scenes+ (each scene's name
      # with its {Profiler::Result}). Nil when none of them ran a frame.
      def self.busiest_in(scenes)
        scene, reading = scenes.reject { |_, r| r.frames.zero? }.max_by { |_, r| r.samples.fdiv(r.frames) }
        reading && Busiest.new(scene: scene, shares: reading.lines.to_h { |line| [line.name, line.share] })
      end

      # The busiest scene as a saved profile keeps it, read back. Nil for a profile saved
      # without one.
      def self.busiest_from(saved)
        return nil unless saved

        Busiest.new(scene: saved["scene"]&.to_sym, shares: saved.fetch("shares", {}).transform_keys(&:to_sym))
      end

      def write(path)
        File.write(path, "#{JSON.pretty_generate(as_json)}\n")
        path
      end

      def as_json
        saved = { "game" => game, "measured_at" => measured_at, "routines" => counts_as_json(work) }
        saved["scenes"] = scenes.to_h { |scene, counts| [scene.to_s, counts_as_json(counts)] } unless scenes.empty?
        saved["lists"] = counts_as_json(touches) if touches
        saved["scene_lists"] = scene_touches.to_h { |scene, counts| [scene.to_s, counts_as_json(counts)] } unless scene_touches.empty?
        return saved unless busiest

        saved.merge("busiest_scene" => { "scene" => busiest.scene&.to_s,
                                         "shares" => busiest.shares.transform_keys(&:to_s) })
      end

      # Instructions a frame, or nil when the profile has never seen this routine — added since
      # the measuring, which is different from one measured at nothing.
      def work_of(name) = work[name]

      def measured?(name) = work.key?(name)

      # What part of the busiest scene's work +name+ did (see Busiest). A share is the wrong
      # thing to rank by (see #work) and the right thing to SAY, since "a tenth of a frame's
      # work" means something to an author where a count of instructions does not.
      #
      # Nil when this profile kept no busiest scene, and nil for a routine it never saw — new
      # since the measuring, which is different from one that did nothing in that scene.
      def busiest_share_of(name)
        return nil unless busiest && measured?(name)

        Share.new(percent: busiest.shares.fetch(name, 0.0), scene: busiest.scene)
      end

      # The routines this profile names that the program no longer has. Almost always a rename or
      # a deletion, and worth saying out loud: a profile that has drifted from its game keeps
      # deciding the placement, quietly and increasingly wrongly.
      #
      # Only routines somebody WROTE are counted. The build makes routines of its own as it goes
      # — one glyph walker per font, and so on — and those appearing and disappearing is the
      # build doing its job, not the author losing track of a name.
      def stale_routines(known) = work.keys.grep_v(/\A__/) - known.to_a

      # +names+ ordered by what a frame was measured to spend in each, dearest first. A routine
      # the profile never saw goes last, in the order it was given — it is new since the
      # measuring, and nothing here can say what it costs.
      def order_by_work(names)
        measured, unmeasured = names.partition { |name| measured?(name) }
        measured.sort_by { |name| [-work.fetch(name), name.to_s] } + unmeasured
      end

      # A routine has to do enough work to be worth the room. The same job WORTH_MOVING did for
      # the estimate, said against a measurement instead of a price.
      #
      # WHERE THE FLOOR COMES FROM: a call that crosses between the two memories is four
      # instructions where a plain one is a single branch, so moving a routine costs about three
      # instructions at every call site, every frame. It gives back a bit over half of what the
      # routine itself runs. So a routine running a couple of dozen instructions a frame is about
      # breaking even, and below that it is paying for room it does not need. It also keeps an
      # idle game — one asleep nine tenths of every frame — from filling the quick memory with
      # the handful of instructions that are all it runs.
      WORTH_MOVING = 24

      def worth_quick_memory?(name) = work.fetch(name, 0) >= WORTH_MOVING

      # WHAT ONE READ OF A LIST IS WORTH, in instructions of a routine — so a list and a routine
      # can be weighed for the same room by the same count.
      #
      # A read of the quick memory takes one cycle. A read of the roomy memory waits: six cycles
      # for a whole word, three for a half or a byte, since its chip hands over half a word at a
      # time. So keeping a list in the quick memory saves five cycles a read of a word and two a
      # read of anything narrower. An instruction kept in the quick memory saves a bit over one
      # cycle — it runs about two and a third times as fast as from the cartridge — so a read of a
      # word is worth about four instructions, and a read of a half or a byte about one and a half.
      CYCLES_SAVED_BY_READ = { 4 => 5, 2 => 2, 1 => 2 }.freeze
      CYCLES_SAVED_BY_INSTRUCTION = Rational(4, 3)

      # What a frame was measured to save by keeping +lists+ (each list's name with how many bytes
      # a slot of it is) in the quick memory, in instructions a frame: added up over the scenes,
      # or of one +scene+'s frames. nil where this profile counted none of them — it counted no
      # list at all, or these were added since — which leaves the build to the order it keeps
      # without a measurement.
      def worth_of_lists(lists, scene: nil)
        return nil unless touches && lists.keys.any? { |name| touches.key?(name) }

        counts = scene ? scene_touches.fetch(scene, {}) : touches
        lists.sum { |name, width| counts.fetch(name, 0) * CYCLES_SAVED_BY_READ.fetch(width) / CYCLES_SAVED_BY_INSTRUCTION }
             .round
      end

      # ...and what a frame of each scene was measured to save by keeping them, by the scene's name.
      def worth_of_lists_by_scene(lists) = scene_touches.keys.to_h { |scene| [scene, worth_of_lists(lists, scene: scene)] }

      # HOW MANY TIMES ONE FRAME TOUCHED EACH LIST, by its name: the most any one scene's frame
      # did, since the counts added up over the scenes are no one frame's. A game with no scenes
      # has only the one count. nil where this profile counted no list.
      def touches_in_one_frame
        return touches if touches.nil? || scene_touches.empty?

        scene_touches.values.reduce({}) { |most, counts| most.merge(counts) { |_, a, b| [a, b].max } }
      end

      private

      # Counts by routine, dearest first, as a saved profile keeps them.
      def counts_as_json(counts) = counts.sort_by { |_, n| -n }.to_h { |name, n| [name.to_s, n] }
    end
  end

end
