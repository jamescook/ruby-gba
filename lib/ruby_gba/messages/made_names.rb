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
    # or, for a save record and a pool, before a double underscore no record's or pool's name
    # can hold. So a record called :jobs is a record, not the save queue, a font called
    # :buffered_tiny cannot meet the tear-free screen's routine for :tiny, and the lists of
    # pool :guard_walk are never the lists of pool :guard.
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

      # WHAT A POOL CAN BE CALLED: anything that does not hold two underscores in a row or end
      # in one — which `pool` holds a game to. A pool's own names put its name before TWO
      # underscores, so held to this shape the first pair of them is always where the name
      # ends, whatever comes after: a part of the pool's own, or a field called anything.
      POOL = "(?:_?[^_])+"
      POOL_NAME = /\A#{POOL}\z/

      # What a report calls each of a pool's routines.
      POOL_JOBS = { remove: "removing an instance of pool :%s",
                    release_removed: "freeing the slots of pool :%s that a walk removed",
                    append: "putting a new instance of pool :%s last in its order",
                    unlink: "taking an instance of pool :%s out of its order" }.freeze

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
                                return job.sub("save_data :%s", SAVE_VAR_WORDS) if parts[:record].start_with?("_")

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
        scene_rows_hidden_for: Kind.new(spelling: "__scene_rows_hidden_for_%{state}", parts: { state: ANY }, words: nil),
        scene_rows_hide: Kind.new(spelling: "__hide_scene_rows_%{state}", parts: { state: ANY },
                                  words: ->(_) { "hiding the sprites of a scene that went" }),
        scene_loop_work: Kind.new(spelling: "__loop_for_scene_%{scene}__%{number}", parts: { scene: ANY, number: "\\d+" },
                                  words: ->(parts) { "the game loop's own work for scene :#{parts[:scene]}" }),
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
        # A loop in the setting up that pushes into a list, which costs with the list's capacity
        # (see Backends::GBA#setting_up_addresses).
        setup_fill: Kind.new(spelling: "__setup_fill_%{list}", parts: { list: ANY },
                             words: lambda do |parts|
                               "filling #{MadeNames.collection_words(parts[:list])} a push at a time, before the game loop"
                             end),
        told_turn: Kind.new(spelling: "__bg_%{background}_told_%{part}", parts: { background: ANY, part: PLAIN },
                            words: nil),
        set_swap: Kind.new(spelling: "__set_swap_%{background}", parts: { background: ANY },
                           words: ->(parts) { "bringing background :#{parts[:background]} another set of tiles" }),
        shared_rooms: Kind.new(spelling: "__shared_rooms_%{number}__%{part}", parts: { number: "\\d+", part: PLAIN },
                               words: lambda do |parts|
                                 if parts[:part] == "take"
                                   "giving a sprite a room in sprite memory for the pose it shows"
                                 else
                                   "taking back the room of a sprite that is not shown"
                                 end
                               end),
        view_along_map: Kind.new(spelling: "__view_along_map_%{background}", parts: { background: ANY },
                                 words: ->(parts) { "bringing the view of background :#{parts[:background]} along its map" }),
        pool_stacking: Kind.new(spelling: "__stacking_pool_%{pool}", parts: { pool: ANY },
                                words: ->(parts) { "putting the sprites of pool :#{parts[:pool]} oldest in front" }),
        # A pool's field is a list, and so is much of what the pool keeps for itself. The two
        # start differently, so a field called `frame`, `active` or `count` is never the
        # pool's own list of that name.
        pool_field: Kind.new(spelling: "__poolfield_%{pool}__%{field}", parts: { pool: POOL, field: ANY },
                             words: nil),
        pool_part: Kind.new(spelling: "__pool_%{pool}__%{part}", parts: { pool: POOL, part: PLAIN },
                            words: lambda do |parts|
                              job = POOL_JOBS[parts[:part].to_sym]
                              job && format(job, parts[:pool])
                            end),
        draw_order: Kind.new(spelling: "__draw_order_%{number}__%{part}", parts: { number: "\\d+", part: PLAIN },
                             words: lambda do |parts|
                               "putting the sprites of draw_in_order ##{parts[:number]} in order" if parts[:part] == "sort"
                             end),
        see_through_amounts: Kind.new(spelling: "__see_through_%{layer}", parts: { layer: ANY },
                                      words: ->(parts) { "telling the display how see-through layer :#{parts[:layer]} is" }),
      }.then { |kinds| Ractor.make_shareable(kinds) }

      # Each kind's spelling as the pattern a name is read back with, worked out once: a
      # report or a guardrail reads every list and routine of a game back through these.
      PATTERNS = KINDS.transform_values(&:pattern).then { |patterns| Ractor.make_shareable(patterns) }

      def self.kinds = KINDS.keys

      # The name of the +kind+ made from +parts+ (see KINDS for each kind's parts).
      def self.make(kind, **parts)
        KINDS.fetch(kind).make(parts)
      end

      # Which kind +name+ is and the parts it was made from, as [kind, { part => String }], or
      # nil for a name the build did not make.
      def self.read(name)
        said = name.to_s
        PATTERNS.each do |kind, pattern|
          found = pattern.match(said) or next
          return [kind, found.named_captures.transform_keys(&:to_sym)]
        end
        nil
      end

      # What a report calls the collection a list belongs to — the thing the author declared,
      # since a list the build made up has a name the author never wrote. A pool is a list a
      # field and several of its own, and reads as its pool. A save_data record keeps lists of
      # its own too — the buffer a save is copied into first, the place each copy is in — and
      # reads as the record. A canvas keeps its pixels in one, and a draw order its order.
      # Any other list reads as itself.
      def self.collection_words(list_name)
        kind, parts = read(list_name)
        case kind
        when :pool_field, :pool_part then "pool :#{parts[:pool]}"
        when :save_record, :save_directory then save_record_words(parts[:record])
        when :save_table, :save_places, :save_jobs then SAVE_BOOKKEEPING_WORDS
        when :canvas_part then "canvas :#{parts[:canvas]}"
        when :draw_order then "draw_in_order ##{parts[:number]}"
        else "list :#{list_name}"
        end
      end

      # Is +list_name+ one a save_data record keeps for itself? Its size follows what the record
      # keeps, so what to do about a big one is keep less, not give it a smaller capacity.
      def self.save_list?(list_name)
        kind, = read(list_name)
        %i[save_record save_directory save_table save_places save_jobs].include?(kind)
      end

      # What the save machinery that belongs to no one record is called: the table of where
      # each record lives, and the line saves wait in.
      SAVE_BOOKKEEPING_WORDS = "the save_data bookkeeping"

      SAVE_VAR_WORDS = "the save_var numbers"

      # The record +record+ as the author wrote it, or as what it is for one of the framework's
      # own two, known by their exact names (IR::SaveLayout): where the save_vars are kept on
      # flash or the EEPROM, and the table of where each record lives.
      def self.save_record_words(record)
        case record.to_sym
        when IR::SaveLayout::TABLE_RECORD then SAVE_BOOKKEEPING_WORDS
        when IR::SaveLayout::SAVE_VAR_RECORD then SAVE_VAR_WORDS
        else "save_data :#{record}"
        end
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
