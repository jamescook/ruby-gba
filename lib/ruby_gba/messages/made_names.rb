# frozen_string_literal: true

module RubyGBA
  module Messages
    # THE NAMES THE BUILD MAKES UP, for routines and variables nobody wrote: the routines a
    # `save_data` record is built into and the save machinery behind them, the routine each
    # font's numbers are drawn by, the routine that writes one scene's sprites. Each kind is
    # written here ONCE — how its name is spelled from its parts, and what a report calls it —
    # and the build makes every such name here and reads every one back here.
    #
    # That is what keeps them apart. A name is spelled with the game's own part (a record's
    # name, a font's, a scene's) after a fixed start that no other kind's start begins with,
    # or, for a save record, before a double underscore no record name can hold. So a record
    # called :jobs is a record, not the save queue, and a font called :buffered_tiny cannot
    # meet the tear-free screen's routine for :tiny.
    #
    # Reading a name back is worked out from the same spelling, so a name made and a name read
    # cannot disagree about where one part ends and the next begins.
    module MadeNames
      # How one kind is spelled — a template naming its parts, "%{part}" — what shape each
      # part may take, and, for a routine a report can name, what it is called.
      Kind = Data.define(:spelling, :parts, :words) do
        def make(values)
          format(spelling, **values).to_sym
        end

        def pattern
          Regexp.new("\\A#{Regexp.escape(spelling).gsub(/%\\\{(\w+)\\\}/) do
            "(?<#{Regexp.last_match(1)}>#{parts.fetch(Regexp.last_match(1).to_sym)})"
          end}\\z")
        end
      end

      # What a report calls each of a save record's routines.
      SAVE_JOBS = { scan: "looking a copy of save_data :%s over", save: "saving save_data :%s",
                    step: "writing save_data :%s a piece at a time",
                    load: "loading save_data :%s", erase: "erasing a copy of save_data :%s",
                    copy: "copying one copy of save_data :%s over another",
                    reset: "putting save_data :%s's things back as declared",
                    autosave: "asking for a save of save_data :%s after a change" }.freeze

      # WHAT A RECORD CAN BE CALLED: letters and digits, with one underscore between words —
      # which `save_data` holds a game to. A record's own names put its name before TWO
      # underscores and the save machinery's start with one, so held to this shape a record's
      # name can never run into the piece after it, into another record's, or into the
      # framework's.
      RECORD_NAME = /\A[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*\z/

      # The same, read back — and the table of places, which is kept the way a record is and
      # named with two underscores in front so no record can be called it, and the record the
      # `save_var`s are kept in on flash, named with one.
      RECORD = "_*[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*"
      PLAIN = "[A-Za-z0-9_]+"
      ANY = ".+"

      PLACES_WORDS = "finding where each save_data record lives in save memory"
      DIGIT_WORDS = ->(parts) { "drawing a draw_number's digits (:#{parts[:font]})" }

      # In the order a name is read back in: a directory entry ends in "_of" and would
      # otherwise read as a record's piece, so it is tried first.
      KINDS = {
        save_directory: Kind.new(spelling: "__save_%{record}__%{kept}_of", parts: { record: RECORD, kept: ANY },
                                 words: nil),
        save_record: Kind.new(spelling: "__save_%{record}__%{piece}", parts: { record: RECORD, piece: PLAIN },
                              words: lambda do |parts|
                                return PLACES_WORDS if parts[:record].start_with?("__")

                                job = SAVE_JOBS[parts[:piece].to_sym] or return nil
                                # The one record named with one underscore is save_var's.
                                return job.sub("save_data :%s", "the save_var numbers") if parts[:record].start_with?("_")

                                format(job, parts[:record])
                              end),
        save_table: Kind.new(spelling: "__save__table_%{column}", parts: { column: PLAIN }, words: nil),
        save_places: Kind.new(spelling: "__save__places_%{piece}", parts: { piece: PLAIN },
                              words: ->(_) { PLACES_WORDS }),
        save_jobs: Kind.new(spelling: "__save__jobs_%{piece}", parts: { piece: PLAIN },
                            words: ->(_) { "keeping the save_data saves in line" }),
        digit_routine: Kind.new(spelling: "__digit_routine_direct_%{font}", parts: { font: ANY }, words: DIGIT_WORDS),
        buffered_digit_routine: Kind.new(spelling: "__digit_routine_buffered_%{font}", parts: { font: ANY },
                                         words: DIGIT_WORDS),
        scene_sprites: Kind.new(spelling: "__sprites_scene_%{scene}", parts: { scene: ANY },
                                words: ->(parts) { "moving the sprites of scene :#{parts[:scene]}" }),
        scene_sprites_shown: Kind.new(spelling: "__sprites_shown_%{scene}", parts: { scene: ANY }, words: nil),
        still_sprites: Kind.new(spelling: "__still_objects", parts: {},
                                words: ->(_) { "writing the sprites nothing moves" }),
        tile_run_tile: Kind.new(spelling: "__tile_run_%{run}__%{number}", parts: { run: ANY, number: "\\d+" },
                                words: nil),
        pose_rows: Kind.new(spelling: "__pose_rows_%{number}", parts: { number: "\\d+" }, words: nil),
        tile_run_pending: Kind.new(spelling: "__tile_runs_pending_%{number}", parts: { number: "\\d+" }, words: nil),
        painted_copies: Kind.new(spelling: "__painted_copies", parts: {},
                                 words: ->(_) { "copying the pictures and tiles the game painted" }),
        canvas_part: Kind.new(spelling: "__canvas_%{canvas}__%{part}", parts: { canvas: ANY, part: PLAIN },
                              words: lambda do |parts|
                                "painting a pixel of canvas :#{parts[:canvas]}" if parts[:part] == "pixel"
                              end),
        canvas_font: Kind.new(spelling: "__letters_%{font}__%{part}", parts: { font: ANY, part: PLAIN },
                              words: nil),
        list_fill_routine: Kind.new(spelling: "__list_fill_bytes", parts: {},
                                    words: ->(_) { "filling a run of a list, as a canvas clears or fills a rectangle" }),
        list_copy_routine: Kind.new(spelling: "__list_copy_bytes", parts: {},
                                    words: ->(_) { "copying a run of a table into a list" }),
        told_turn: Kind.new(spelling: "__bg_%{background}_told_%{part}", parts: { background: ANY, part: PLAIN },
                            words: nil),
        see_through_amounts: Kind.new(spelling: "__see_through_%{layer}", parts: { layer: ANY },
                                      words: ->(parts) { "telling the display how see-through layer :#{parts[:layer]} is" }),
      }.then { |kinds| Ractor.make_shareable(kinds) }

      def self.kinds = KINDS.keys

      # The name of the +kind+ made from +parts+ (see KINDS for each kind's parts).
      def self.make(kind, **parts)
        KINDS.fetch(kind).make(parts)
      end

      # Which kind +name+ is and the parts it was made from, as [kind, { part => String }], or
      # nil for a name the build did not make.
      def self.read(name)
        said = name.to_s
        KINDS.each do |kind, spelling|
          found = spelling.pattern.match(said) or next
          return [kind, found.named_captures.transform_keys(&:to_sym)]
        end
        nil
      end

      # What a report calls the routine +name+, or nil when it is not one the build made up (or
      # is a made-up variable, which no report names).
      def self.words_for_made_name(name)
        kind, parts = read(name)
        kind && KINDS.fetch(kind).words&.call(parts)
      end
    end
  end
end
