# frozen_string_literal: true

require "json"

module RubyGBA
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
      # quick memory is chosen by (see #order_by_scene_work).
      attr_reader :scenes

      def initialize(work:, game: nil, measured_at: nil, busiest: nil, scenes: {})
        @work = work
        @game = game
        @measured_at = measured_at
        @busiest = busiest
        @scenes = scenes
      end

      # Read a saved profile. Returns nil when there is no file — a missing profile is the
      # ordinary case on a first build, not an error.
      def self.read(path)
        return nil unless path && File.file?(path)

        data = JSON.parse(File.read(path))
        new(work: data.fetch("routines", {}).transform_keys(&:to_sym),
            game: data["game"], measured_at: data["measured_at"], busiest: busiest_from(data["busiest_scene"]),
            scenes: data.fetch("scenes", {}).to_h { |scene, counts| [scene.to_sym, counts.transform_keys(&:to_sym)] })
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
            scenes: survey.scenes.filter_map { |scene, reading| [scene, Profiler.work_in(reading)] if scene }.to_h)
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
      def order_by_work(names) = order_measured_first(names) { |name| work.fetch(name) }

      # +names+ ordered by the most a frame of any one scene was measured to spend in each,
      # dearest first — the second order the scenes' shares of the quick memory are tried in
      # (see GBA::SceneQuickMemory#choose_scene_sets). Added up over every scene, a routine two
      # scenes run reads dearer than one scene's own busier routine, though a frame of either
      # spends less in it. With no scene's counts, it is #order_by_work.
      #
      # A routine measured but in no scene's counts ranks at nothing, behind every scene's
      # routines and ahead of the ones never measured. The game loop is one, and it is placed
      # before anything this orders.
      def order_by_scene_work(names)
        return order_by_work(names) if scenes.empty?

        order_measured_first(names) { |name| scenes.values.map { |counts| counts.fetch(name, 0) }.max }
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

      private

      # +names+ the profile measured, dearest by the block first, then the rest as given.
      def order_measured_first(names, &cost)
        measured, unmeasured = names.partition { |name| measured?(name) }
        measured.sort_by { |name| [-cost.call(name), name.to_s] } + unmeasured
      end

      # Counts by routine, dearest first, as a saved profile keeps them.
      def counts_as_json(counts) = counts.sort_by { |_, n| -n }.to_h { |name, n| [name.to_s, n] }
    end
  end

end
