# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A SAVE STARTED FOR THE SAKE OF MEASURING IT. A measured build plays each scene with nobody at
    # the controls, so nobody ever saves, and the routines that write a save a piece a pass measured
    # as nothing. A game that wanted them in the quick memory had to say `fast: true`, which puts
    # them ahead of everything the build chooses — the routine every frame runs among them.
    #
    # So a scene whose code asks for a save, an erase or a copy of a record is measured again with a
    # save of that record's copy 0 already running as its frames begin, the way it would be the pass
    # after the player chose to save there. A save is written in a few passes and then stops, and a
    # routine's work is counted over every frame measured, so the save weighs what a share of the
    # scene's frames spend on it — not what it would if the scene saved every frame. The save is started the way the game's own request
    # leaves one, by writing the queue's running job; what it writes into save memory is whatever
    # the record's buffer held, which does not matter to a run nobody keeps. A scene that never
    # saves is measured as it was.
    module SaveStarts
      # What a scene's code calls to ask for a job of a record, by the name its routine was made
      # under (see Builder::SaveRecords).
      ASKS = %i[save erase copy].freeze

      module_function

      # The words to write once as +scene+'s measured frames begin, [address, value] each: the
      # running job set to a save of the first record the scene asks a job of — a save even where
      # the scene only erases or copies, since all three are written by the same routine, a piece a
      # pass. None for a scene that asks none, or a build that keeps no queue.
      def words(built, scene)
        program = built.source_program
        record = records_asked_in(program, scene).first or return []
        number = Builder::SaveJobs.record_numbers(program)[record] or return []

        Builder::SaveJobs.save_started(number).filter_map do |name, value|
          address = built.var_addresses[name] and [address, value]
        end
      end

      # The records +scene+ asks a job of, in the order its code reaches them: through every
      # routine its own routine calls, however deep.
      def records_asked_in(program, scene)
        bodies = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
        start = scene_routine(program, scene) or return []
        seen = Set.new
        records = []
        visit = lambda do |name|
          next if seen.include?(name)

          seen << name
          kind, parts = Messages::MadeNames.read(name)
          records << parts[:record].to_sym if kind == :save_record && ASKS.include?(parts[:piece].to_sym)
          bodies[name]&.walk&.each { |node| visit.call(node.target) if node.kind == :call }
        end
        visit.call(start)
        records.uniq
      end

      # The routine the game's dispatch runs for +scene+ (see Analyzer#scenes, which names each
      # scene by it).
      def scene_routine(program, scene)
        dispatch = program.walk.find { |node| node.kind == :case } or return nil
        dispatch.clauses.map(&:last).find { |func| func.to_s.delete_prefix("_scene_").to_sym == scene }
      end
    end
  end
end
