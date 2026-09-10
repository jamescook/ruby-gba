# frozen_string_literal: true

require "json"

module RubyGBA
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
    attr_reader :work, :game, :measured_at

    def initialize(work:, game: nil, measured_at: nil)
      @work = work
      @game = game
      @measured_at = measured_at
    end

    # Read a saved profile. Returns nil when there is no file — a missing profile is the
    # ordinary case on a first build, not an error.
    def self.read(path)
      return nil unless path && File.file?(path)

      data = JSON.parse(File.read(path))
      new(work: data.fetch("routines", {}).transform_keys(&:to_sym),
          game: data["game"], measured_at: data["measured_at"])
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

    # ...and from what {Profiler.every_scene} answers, which is already instructions a frame
    # per routine, taken at each routine's busiest scene.
    def self.from_work(work, game: nil)
      new(work: work, game: game, measured_at: Time.now.utc.iso8601)
    end

    def write(path)
      File.write(path, "#{JSON.pretty_generate(as_json)}\n")
      path
    end

    def as_json
      { "game" => game, "measured_at" => measured_at,
        "routines" => work.sort_by { |_, n| -n }.to_h { |name, n| [name.to_s, n] } }
    end

    # Instructions a frame, or nil when the profile has never seen this routine — added since
    # the measuring, which is different from one measured at nothing.
    def work_of(name) = work[name]

    def measured?(name) = work.key?(name)

    # The routines this profile names that the program no longer has. Almost always a rename or
    # a deletion, and worth saying out loud: a profile that has drifted from its game keeps
    # deciding the placement, quietly and increasingly wrongly.
    #
    # Only routines somebody WROTE are counted. The build makes routines of its own as it goes
    # — one glyph walker per font, and so on — and those appearing and disappearing is the
    # build doing its job, not the author losing track of a name.
    def forgotten(known) = work.keys.grep_v(/\A__/) - known.to_a

    # +names+ ordered by what a frame was measured to spend in each, dearest first. A routine
    # the profile never saw goes last, in the order it was given — it is new since the
    # measuring, and nothing here can say what it costs.
    def rank(names)
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

    def worth_moving?(name) = work.fetch(name, 0) >= WORTH_MOVING
  end

end
