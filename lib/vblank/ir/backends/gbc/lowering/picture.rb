# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # THE PICTURE, lowered for a Game Boy Color: the statements that draw, as calls into
          # Runtime::Picture and Runtime::Paint, and the art they draw with, made into tiles and
          # palettes (GBC::Art). Mixed into Lowering.
          #
          # On the Advance's desktop build the runtime paints every pixel; on the Color the console
          # does. So little here is painted: a sprite is entries in the console's sprite table, a
          # background is its grid of cells, and what the game does to either changes those. A
          # painted screen (`screen :bitmap`) is the one exception, 360 tiles the runtime paints
          # into (Runtime::Paint).
          module Picture
            STATEMENTS = Ractor.make_shareable({
                                                 screen: :emit_screen, clear_screen: :emit_clear_screen,
                                                 fill_rect: :emit_fill_rect, dma_fill_rect: :emit_fill_rect,
                                                 draw_rect_at: :emit_fill_rect, pixel: :emit_pixel,
                                                 draw_text: :emit_draw_text, draw_digit: :emit_draw_digit,
                                                 inside: :emit_inside, blit: :emit_blit, blit_pose: :emit_blit_pose,
                                                 draw_column_at: :emit_draw_column_at,
                                                 save_region: :emit_save_region, restore_region: :emit_restore_region,
                                                 background: :emit_background, scroll_background: :emit_scroll_background,
                                                 place_bar: :emit_place_bar,
                                                 show_map: :emit_show_map, set_tile: :emit_set_tile,
                                                 background_colors: :emit_background_colors,
                                                 scroll_rows: :emit_scroll_rows, camera: :emit_camera,
                                                 present_objects: :emit_present_objects, hide_sprites: :emit_hide_sprites,
                                                 show_picture_group: :emit_show_picture_group,
                                                 color_list_holds: :emit_color_list_holds,
                                                 fade: :emit_fade, tint: :emit_tint
                                               })

            VALUES = Ractor.make_shareable({ pixels_overlap: :value_of_pixels_overlap })

            # What a column of a picture is handed over in (#emit_draw_column_at), the height first.
            COLUMN = %i[height slice x top width].freeze

            # One table of the drawing's numbers, as #drawing_table keeps it for the data.
            DrawingTable = Data.define(:label, :bytes, :entries, :banked)

            # A pose's entry in a sprite's table of the group holding each of its pictures
            # (#emit_held_group_check) when no one group holds it. A group's number is always less
            # (Runtime::PictureGroups::MOST_GROUPS).
            IN_NO_ONE_GROUP = 0xFF

            # The art the program's pictures were made into, for the cartridge to keep.
            attr_reader :art

            # How many rows of the window's grid the game's status bars fill, the most of any of
            # them, or nil for a game with none (Runtime::Picture#emit_bar).
            def bar_rows
              bars = @backgrounds.each_value.select(&:bar?)
              bars.map { |bar| TileMap.size_of(bar.map).last }.max unless bars.empty?
            end

            # Where a game that draws a background with other colours keeps the colours its pictures
            # are drawn in now, every palette's (Runtime::Picture#emit_background_colors), or nil for
            # a game that never does.
            attr_reader :drawn_palettes

            # Where a game with a map bigger than the grid keeps its copy of the grid and its list of
            # cells for the blank, [copy, list] (Runtime::BigMaps), or nil for a game with none.
            attr_reader :big_map_places

            # Has the game a set of picture groups with more than one slot, whose groups up together
            # the runtime asks about (Runtime::Frame#emit_groups_together)?
            def groups_up_together? = sets_of_many_slots.any?

            # Each set #emit_refuse_groups_not_together asks of, by its number (GBC::TogetherCheck).
            def together_checks
              @together_checks.map do |groups, named, slots|
                TogetherCheck.new(groups: groups, group_numbers: named, said_at: slots.map { |slot| place_of(slot) })
              end
            end

            # What each check of #emit_refuse_pictures_not_up asks, by its number (GBC::PictureCheck).
            def picture_checks
              @picture_checks.map do |sprite, groups, poses, holdings, named, slots|
                PictureCheck.new(sprite: sprite, groups: groups, poses: poses, holdings: holdings, group_numbers: named,
                                 said_at: slots.map { |slot| place_of(slot) })
              end
            end

            # Are any sprites left as they were when nothing they are placed from changed? Asked by
            # the build, to keep the runtime's room for it. A sprite is kept so when each number it is
            # placed from is a variable, or a number written in the program, since a write of a
            # variable is where it is marked changed (Lowering#store); one placed from a number worked
            # out as the pass goes is placed every pass. Not in a game whose pictures come and go in
            # groups, whose placing checks the picture is up.
            def keeps_unchanged_sprites? = @picture_sets.empty? && !kept_sprites.empty?

            private

            # THE COLOUR THE GAME SHOWS WHEREVER NOTHING IS DRAWN (IR::SceneHandover#game_backdrop).
            # The Color has no one backdrop colour: each of its background palettes keeps its own
            # first colour, which the see-through pixels of the tiles drawn from it show, and an
            # empty cell shows the first palette's. So the backdrop is built into every palette, and
            # a `screen` that says another (#refuse_backdrops_of_its_own!) is refused.
            def color_backdrop = IR::SceneHandover.of(@program).game_backdrop

            # How tall the console draws every sprite piece: 16 where the game named the Color's 8×16
            # (`sprite_piece_size: { gbc: [8, 16] }`), 8 otherwise (Art#initialize).
            def piece_height = (@program.sprite_piece_size_on(Console::COLOR.name) || [8, 8]).last

            # A `screen` other than the game's own that says a backdrop the game's does not: a scene's
            # would have every palette written again as it takes over. Named by its scene.
            def refuse_backdrops_of_its_own!
              handover = IR::SceneHandover.of(@program)
              @program.walk.each do |node|
                next unless node.kind == :screen && node.backdrop && node.backdrop != handover.game_backdrop

                scene = handover.scene_of_screen(node)
                where = scene ? "the scene #{Modes.strip_scene_prefix(scene).to_sym.inspect}" : "a `screen` in a routine"
                raise LoweringError, "#{where} says a backdrop of its own. A Game Boy Color keeps the backdrop in " \
                                     "each of its colour lists, so a game shows one backdrop on the Color. To fix " \
                                     "this, say backdrop: on the game's own `screen` alone."
              end
            end

            def prepare_picture
              refuse_backdrops_of_its_own!
              @stacking = Stacking.picture(@program)
              @objects = by_name(@program.walk, :object)
              @color_lists = by_name(@program.walk, :color_list)
              @pictures = by_name(@program.walk, :data, :bitmap)
              @square_colors = square_colors
              @picture_sets = by_name(@program.walk, :picture_groups)
              @art = Art.new(square_colors: @square_colors&.refusal ? nil : @square_colors, lends: @lends_sprite_colors,
                             grouped: grouped_pictures, room_colors: @plans_room_colors,
                             first_cleared_to: @program.walk.find { |node| node.kind == :clear_screen }&.color,
                             backdrop: color_backdrop, piece_height: piece_height)
              @grids = {} # a background declaration -> its grid's number
              @backgrounds = by_name(@program.walk, :background)
              @drawn_sprites = SpriteNames.new(@program) # the numbers a run says its sprites by
              @patches = by_name(@program.walk, :backing_buffer) # what sprites on a painted screen cover
              @column_routines = {} # a picture drawn a column at a time -> its routine's label
              @drawing_tables = [] # DrawingTable each, for the data
              @picture_checks = [] # what each check asks, by its number (#picture_checks)
              @together_checks = [] # [set, the numbers naming a group, the slots] each (#together_checks)
              plan_tile_rooms if @plans_tile_rooms
            end

            # --- the tiles each screen brings in ---

            # WHICH TILES EACH SCREEN BRINGS IN AS IT COMES UP (GBC::Art::Room), for a game whose
            # backgrounds need more tiles than the Color holds at once (GBC#build). The tiles every
            # screen shows are kept from power-on: those of the backgrounds declared in no scene, and
            # the tiles the game paints from lists, which it may paint while any screen is up. Each
            # scene's own backgrounds' tiles are a room of that scene's, numbered from past those, so
            # two scenes' rooms take turns with the same picture memory. A background that walks
            # between areas has a room for each area, past its scene's own tiles, and the room of the
            # area a map is in comes in as that map is shown.
            #
            # A background counts the tiles its maps show and the ones `set_tile` puts in its cells, as
            # a game whose tiles all fit counts them (a tile is numbered as something first names it),
            # not every tile of its tileset.
            def plan_tile_rooms
              tile_runs.each_value { |run| run.tiles.each { |tile| @art.run_tile(tile, run.colors) } unless run.picture }
              every = tiled_scenery.reject(&:scene)
              every.reject(&:several_sets?).each { |bg| tiles_shown(bg).each { |name| background_tile_named(name, bg) } }
              @art.keep_art_asked_so_far
              @tile_rooms = {} # [scene, area] -> the Room brought in for a screen of that scene, at that area
              @scene_rooms = {} # a scene -> the Room its own tiles are numbered in
              @room_scenes = {} # a Room's id -> the scene it is brought in for, :every for every screen
              tiled_scenery.filter_map(&:scene).uniq.each { |scene| plan_scene_room(scene) }
              plan_rooms_for_bare_scenes
              walking = every.find(&:several_sets?)
              return unless walking

              refuse_rooms_of_two_kinds!(walking)
              plan_area_rooms(walking, nil)
            end

            # A scene's own tiles: a room brought in as it arrives, or, where it has a background that
            # walks between areas, the tiles each of its areas' rooms brings in first.
            def plan_scene_room(scene)
              own = tiled_scenery.select { |bg| bg.scene == scene }
              walking = own.find(&:several_sets?)
              room = @art.add_room(scene_words(scene), brought_in: walking.nil?)
              @room_scenes[room.id] = scene
              own.reject(&:several_sets?).each { |bg| tiles_shown(bg).each { |name| background_tile_named(name, bg, room) } }
              @scene_rooms[scene] = room
              walking ? plan_area_rooms(walking, room) : @tile_rooms[[scene, nil]] = room
            end

            # A room for each area of +bg+, which walks between areas, past +parent+'s tiles.
            def plan_area_rooms(bg, parent)
              bg.sets.each_with_index do |set, area|
                whose = "the area #{set.inspect} of the background #{bg.name.inspect}"
                room = @art.add_room(bg.scene ? "#{whose} in #{scene_words(bg.scene)}" : whose, parent: parent)
                @room_scenes[room.id] = bg.scene || :every
                tiles_shown(bg, area).each { |name| background_tile_named(name, bg, room) }
                @tile_rooms[[bg.scene, area]] = room
              end
            end

            def scene_words(scene) = "the scene :#{Modes.strip_scene_prefix(scene)}"

            # --- empty cells ---

            # WHETHER AN EMPTY CELL CAN SHOW while +room+'s colours are in (nil for the colours every
            # screen keeps). An empty cell — one a map leaves empty, or past a map's edge — is drawn
            # from the first palette and shows its first colour, black, as the interpreter shows the
            # backdrop there. So the first palette has to keep black first wherever one can show; on
            # screens that never show one, any palette can be first, one drawn with other lists
            # included (GBC::Art#background_palette_number). A room's colours are in only while its
            # scene is up, in a game whose screens bring their colours in — and every scene of such a
            # game puts its own first palette in as it arrives (#plan_rooms_for_bare_scenes); any
            # other colours, on every screen.
            def empty_cells_shown_with?(room)
              scene = @art.room_colors? && room ? @room_scenes.fetch(room.id) : :every
              @empty_cells_shown ||= {}
              return @empty_cells_shown[scene] if @empty_cells_shown.key?(scene)

              @empty_cells_shown[scene] = scene == :every ? empty_cells_shown_anywhere? : screen_shows_empty_cell?(scene)
            end

            # The colours every screen keeps are in from power-on, and until a scene has taken over
            # the console's grid is nothing but empty cells. So only a game with no scenes, whose
            # backgrounds all go up before its first frame shows, can be one that never shows one.
            def empty_cells_shown_anywhere?
              !(@scenes.empty? && scenery_up_before_first_frame?) || screen_shows_empty_cell?(nil)
            end

            # Whether every background is a statement of the game's own, written before anything that
            # can wait for a frame — a loop, a call, a wait, or a statement holding others.
            def scenery_up_before_first_frame?
              statements = @program.children
              first_wait = statements.index { |node| WAITING_KINDS.include?(node.kind) || node.children.any? } || statements.length
              tiled_scenery.all? { |bg| (at = statements.index { |node| node.equal?(bg) }) && at < first_wait }
            end

            WAITING_KINDS = %i[wait_vblank call loop halt].freeze

            # IN A GAME WHOSE SCREENS BRING THEIR COLOURS IN, WHERE EACH PUTS ITS OWN FIRST: every scene on
            # a screen of tiles has a room, one of nothing for a scene with no background of its own, so
            # each arrival puts its first palette in — black alone, for a room with none — and a scene
            # never shows its empty cells in the colours the scene before it put first.
            def plan_rooms_for_bare_scenes
              return unless @art.first_palette_per_room?

              tiled_scenes.compact.reject { |scene| @scene_rooms.key?(scene) }.each do |scene|
                room = @art.add_room(scene_words(scene))
                @scene_rooms[scene] = room
                @room_scenes[room.id] = scene
                @tile_rooms[[scene, nil]] = room
              end
            end

            # The scenes that show a screen drawn from tiles, or the one screen of a game with none.
            def tiled_scenes
              return [nil] if @scenes.empty?

              @scenes.keys.reject { |scene| Modes::SCREEN_OF_MODE.fetch(Modes.resolve(@program).mode_of(scene)) == :bitmap }
            end

            # What +scene+ shows (nil for a game with no scenes) is put up as it arrives
            # (#emit_scene_arrival): its own background, or else every screen's, and every status bar.
            def screen_shows_empty_cell?(scene)
              own = tiled_scenery.select { |bg| bg.scene == scene }
              every = tiled_scenery.select { |bg| bg.scene.nil? }
              ground = own.reject(&:bar?)
              ground = every.reject(&:bar?) if ground.empty?
              ground.empty? || (ground + (own + every).select(&:bar?)).uniq.any? { |bg| background_shows_empty_cell?(bg) }
            end

            # Whether +bg+ can show an empty cell: it moves, a map of it leaves a cell of the screen
            # empty, or `set_tile` can empty one.
            def background_shows_empty_cell?(bg)
              return true if background_moves?(bg)

              h = Console::GBCHardware
              cols = (h::SCREEN_WIDTH + bg.tile_w - 1) / bg.tile_w
              rows = ((bg.bar? ? h::SCREEN_HEIGHT - bg.bar_top : h::SCREEN_HEIGHT) + bg.tile_h - 1) / bg.tile_h
              bg.every_map.any? do |map|
                map.length < rows || map.first(rows).any? do |row|
                  cells = Array(row)
                  cells.length < cols || cells.first(cols).any? { |tile| tile.nil? || tile.negative? }
                end
              end || @reachable.any? { |node| node.kind == :set_tile && node.name == bg.name && !tile_index_known?(node.tile) }
            end

            # Whether a background's view moves, or a status bar's top: any of them past the screen's
            # edge shows the cells beyond it.
            def background_moves?(bg)
              @reachable.any? do |node|
                node.kind == :camera || (%i[scroll_background scroll_rows place_bar].include?(node.kind) && node.name == bg.name)
              end
            end

            # Whether a tile `set_tile` puts in a cell is one the build knows is a tile, never an empty cell.
            def tile_index_known?(tile) = tile.is_a?(Integer) && !tile.negative?

            # The tile pictures +bg+ shows: the ones its maps name — the maps of area number +area+ alone,
            # for a background that walks between areas — and the ones `set_tile` puts in its cells.
            def tiles_shown(bg, area = nil)
              maps = bg.every_map.each_index.select { |which| area.nil? || bg.map_sets.fetch(which) == area }
              named = maps.flat_map { |which| bg.every_map.fetch(which).flat_map { |row| Array(row) } }
              named += @reachable.filter_map { |node| node.tile if node.kind == :set_tile && node.name == bg.name }
              named.compact.reject(&:negative?).uniq.map { |index| bg.tiles.fetch(index) }
            end

            # A background that walks between areas on every screen has its areas' rooms numbered past
            # the tiles every screen keeps, where a scene's own tiles would be too.
            def refuse_rooms_of_two_kinds!(walking)
              owning = @scene_rooms.find { |_, room| room.tiles.any? }
              return unless owning

              raise LoweringError, "the background #{walking.name.inspect} walks between areas on every screen, and " \
                                   "#{scene_words(owning.first)} has backgrounds of its own. Together they need more " \
                                   "tiles than a Game Boy Color holds at one time. To fix this, declare " \
                                   "#{walking.name.inspect} in each scene that shows it."
            end

            # The backgrounds drawn from tiles, every declaration of each: what a screen of tiles shows.
            def tiled_scenery = @tiled_scenery ||= @program.walk.select { |node| node.kind == :background && !painted_screen_for?(node) }

            # The room +bg+'s tiles are numbered in when it shows its map number +which+: its area's, its
            # scene's own, or none, for the tiles every screen keeps. None in a game whose tiles all fit.
            def tile_room(bg, which = 0)
              return unless @tile_rooms
              return @tile_rooms[[bg.scene, bg.map_sets.fetch(which)]] if bg.several_sets?

              @scene_rooms[bg.scene] if bg.scene
            end

            # The room +scene+ brings in as it arrives: its own, or its first area's, or nil for a scene
            # whose tiles are all ones every screen keeps.
            def arrival_room(scene)
              return unless @tile_rooms

              @tile_rooms[[scene, nil]] || @tile_rooms[[scene, 0]]
            end

            # The room of the area +bg+'s map number +which+ is in, brought in before that map's grid
            # goes up; a number naming no map brings nothing in, as it shows nothing new.
            def emit_area_room(bg, which)
              known = folded(which)
              if known
                emit_tile_room(tile_room(bg, known)) if known.between?(0, bg.every_map.length - 1)
                return
              end

              chosen = keep_local(:map)
              value(which)
              store(chosen)
              bg.every_map.each_index do |at|
                other = fresh("not_area_of_map")
                jump_unless(Build.binop(:==, Build.var_ref(chosen), Build.int(at)), other)
                emit_tile_room(tile_room(bg, at))
                @asm.label(other)
              end
            end

            # Bring +room+ in, from the blank after this pass (Runtime::Picture#emit_rooms): its tiles,
            # and its colours where the screens bring theirs in.
            def emit_tile_room(room)
              return unless room&.number && (room.brings_in? || @art.first_palette_per_room?)

              runtime_call("rt_tiles_put_up", [Build.int(room.number)])
            end

            # Each colour list's own number, saying which of its sets it holds now (Reference
            # @held_colors), from power-on the one it was declared with.
            def keep_held_colors
              @held_colors = @color_lists.keys.to_h { |name| [name, keep_local(:"held_#{name}", start: Build::NO_RECOLOR)] }
            end

            def by_name(nodes, *kinds) = nodes.select { |node| kinds.include?(node.kind) }.to_h { |node| [node.name, node] }

            # --- pictures grouped by room ---

            # WHICH PICTURES ARE COPIED IN AS A ROOM COMES UP (Runtime::PictureGroups), each with
            # the set of groups that copies it in. A picture is grouped when a set holds it in a group
            # and every sprite showing it answers to that set — the set of its own scene, or one of
            # every screen — as the interpreter asks (Reference#refuse_pictures_not_up!). One a sprite
            # of another scene shows, or one the game paints, is in sprite memory the whole time.
            def grouped_pictures
              return {} if @picture_sets.empty?

              refuse_too_many_groups!
              scenes = Hash.new { |all, picture| all[picture] = [] }
              @objects.each_value { |obj| Array(obj.poses).each { |picture| scenes[picture] << obj.scene } }
              scenes.filter_map do |picture, shown_in|
                next if picture_painting(picture)

                set = @picture_sets.each_value.find do |each|
                  each.groups_holding(picture).any? && shown_in.all? { |scene| each.scene.nil? || each.scene == scene }
                end
                [picture, set] if set
              end.to_h
            end

            # A slot's group is kept in a byte, with three numbers left over (Runtime::PictureGroups).
            def refuse_too_many_groups!
              most = Runtime::PictureGroups::MOST_GROUPS
              set = @picture_sets.each_value.find { |each| each.groups.length > most }
              return unless set

              raise LoweringError, "the picture groups #{set.name.inspect} number their groups up to " \
                                   "#{set.groups.length - 1}, and #{build_name} numbers them up to #{most - 1}. To fix " \
                                   "this, use fewer groups."
            end

            # Each set's slots, three numbers of the lowering's own each: the group the game said is
            # up (Reference @groups_up), the one the sprites placed last need — a byte, NONE for none
            # — and the one in sprite memory now, which the blank keeps (Runtime::PictureGroups).
            GroupSlot = Data.define(:shown, :wanted, :up)

            def keep_group_numbers
              @group_slots = @picture_sets.transform_values do |set|
                Array.new(set.slots) do
                  GroupSlot.new(shown: keep_local(:groups_shown, start: Nodes::PictureGroups::NONE),
                                wanted: keep_local(:groups_wanted, start: Runtime::PictureGroups::NONE),
                                up: keep_local(:groups_up, start: Runtime::PictureGroups::NOTHING_YET))
                end
              end
            end

            # Reference#exec_show_picture_group. Nothing is copied here: the sprites placed next note
            # the groups they need (#emit_groups_wanted), and the blank after copies them in.
            def emit_show_picture_group(node)
              statement(Build.set(@group_slots.fetch(node.name).fetch(node.slot).shown, node.which))
            end

            # The groups up now, as the sprites about to be placed need them: each slot's, or NONE
            # for a number naming no group — or, for a set of a scene not up yet, FOLLOW, the group
            # the game says by the blank.
            def emit_groups_wanted
              @group_slots.each do |name, slots|
                set = @picture_sets.fetch(name)
                slots.each do |slot|
                  done = fresh("groups_wanted")
                  if set.scene && @scene
                    up = fresh("groups_scene_up")
                    jump_unless(Build.binop(:!=, Build.var_ref(@scene), Build.int(@scenes.fetch(set.scene))), up)
                    statement(Build.set(slot.wanted, Build.int(Runtime::PictureGroups::FOLLOW)))
                    @asm.jump(done)
                    @asm.label(up)
                  end
                  shown = Build.var_ref(slot.shown)
                  statement(Build.set(slot.wanted, Build.int(Runtime::PictureGroups::NONE)))
                  named = Build.binop(:and, Build.binop(:>=, shown, Build.int(0)), Build.binop(:<, shown, Build.int(set.groups.length)))
                  jump_unless(named, done)
                  statement(Build.set(slot.wanted, shown))
                  @asm.label(done)
                end
              end
            end

            # A SPRITE SHOWING A PICTURE NONE OF WHOSE GROUPS IS UP STOPS THE GAME, as the interpreter
            # stops it (Reference#refuse_pictures_not_up!): on the console it would show whatever the
            # groups up put where that picture goes in sprite memory. Asked as the sprite is placed,
            # of every set of its own scene or of every screen that holds the picture in a group,
            # whether the game said one of those groups is up in one of the set's slots. +pose+ is
            # the pose the sprite shows, and +said+ that pose when the program never changes it.
            #
            # A sprite of many pictures is asked by a table of the group holding each, a byte a
            # pose, so the question costs the same whichever it shows; a picture held in several
            # groups of the set is asked of all of them, a question of its own. A sprite that fails
            # is noted as one of #picture_checks, by its number, with the pose, and the game stops
            # once the pass's sprites are placed (rt_picture_not_up), so the reader of the run can
            # say it in the interpreter's words, naming the sprite the interpreter names.
            #
            # A sprite of a scene that has not taken over yet is asked nothing, as the interpreter
            # asks nothing of it (Reference#up_in_this_scene?): its scene says which groups are up
            # as it takes over (#emit_groups_wanted).
            def emit_refuse_pictures_not_up(obj, said, pose)
              asked = fresh("pictures_asked")
              if obj.scene && @scene
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(obj.scene))), asked)
              end
              emit_picture_up_checks(obj, said, pose, asked)
              @asm.label(asked)
            end

            # Every set's checks of the sprite, in the interpreter's order; the first that finds its
            # picture not up notes it and goes to +asked+, past the rest, as the interpreter stops at
            # the first.
            def emit_picture_up_checks(obj, said, pose, asked)
              @picture_sets.each_value do |set|
                next unless set.scene.nil? || set.scene == obj.scene

                holdings = obj.poses.map { |picture| set.groups_holding(picture) }
                next if holdings.all?(&:empty?)

                slots = @group_slots.fetch(set.name).map(&:shown)
                named = group_numbers(set)
                check = Build.int(register_picture_check([obj.declared || obj.name, set.name, obj.poses, holdings, named, slots]))
                ints = ->(groups) { groups.map { |group| Build.int(group) } }
                if said
                  holding = said.negative? ? [] : holdings.fetch(said, [])
                  emit_group_up_check(slots, ints.call(holding), check, pose, asked) unless holding.empty?
                else
                  emit_held_group_check(slots, holdings, check, pose, asked)
                  holdings.each_with_index do |holding, i|
                    next unless holding.length > 1

                    another = fresh("not_this_pose")
                    jump_unless(Build.binop(:==, pose, Build.int(i)), another)
                    emit_group_up_check(slots, ints.call(holding), check, pose, asked, fine: another)
                  end
                end
              end
            end

            # The poses held in one group of the set, by the table: +pose+'s entry is its group, or
            # IN_NO_ONE_GROUP for a pose held in none of the set's groups or in several.
            def emit_held_group_check(slots, holdings, check, pose, asked)
              held_in = holdings.map { |holding| holding.length == 1 ? holding.first : IN_NO_ONE_GROUP }
              return if held_in.all?(IN_NO_ONE_GROUP)

              fine = fresh("held_group_up")
              in_table = Build.binop(:and, Build.binop(:>=, pose, Build.int(0)), Build.binop(:<, pose, Build.int(held_in.length)))
              jump_unless(in_table, fine)
              group = Build.var_ref(keep_local(:held_in))
              value(Entry.new(drawing_table("held_in", 1, held_in), 1, false, pose))
              store(group.name)
              jump_if(Build.binop(:==, group, Build.int(IN_NO_ONE_GROUP)), fine)
              emit_group_up_check(slots, [group], check, pose, asked, fine: fine)
            end

            # Notes the sprite and goes to +asked+ unless one of the set's +slots+ says one of
            # +groups+ (nodes) is up; goes on at +fine+ when one does.
            def emit_group_up_check(slots, groups, check, pose, asked, fine: fresh("group_up"))
              up = slots.product(groups).map { |slot, group| Build.binop(:==, Build.var_ref(slot), group) }
              jump_if(up.reduce { |either, other| Build.binop(:or, either, other) }, fine)
              runtime_call("rt_picture_not_up", [check, pose])
              @asm.jump(asked)
              @asm.label(fine)
            end

            # TWO GROUPS UP TOGETHER THAT up_together DOES NOT SAY CAN BE stop the game, asked of
            # every set of a scene up, or of every screen, as the sprites are about to be placed —
            # before any sprite's picture is asked about, as the interpreter asks
            # (Reference#refuse_pictures_not_up!). A set of one slot can have only one group up.
            #
            # Each set's record for rt_groups_together lists the lists of groups that can be up at
            # once: up_together's, and on its own each group no list of up_together's holds, so a
            # slot holding the same group as another is fine. A number naming no group — none the
            # set has, or a gap in its numbering — is no group up to the interpreter, so every list
            # holds the gaps.
            def emit_refuse_groups_not_together
              sets_of_many_slots.each do |set|
                asked = fresh("groups_together_asked")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(set.scene))), asked) if set.scene && @scene
                runtime_call("rt_groups_together", [Address.new(together_label(set)), Build.int(register_together_check(set))])
                @asm.label(asked)
              end
            end

            # Each set's record, once, with the game's data (Lowering#data_section), however many
            # places the sprites are presented from.
            def emit_together_records(asm)
              sets_of_many_slots.each do |set|
                asm.label(together_label(set))
                asm.data_bytes(together_record(set))
              end
            end

            def together_label(set) = "game_groups_together_#{set.name}"

            # A list holds fewer groups than a byte counts, since a set has fewer than MOST_GROUPS
            # (#refuse_too_many_groups!); how many lists there are takes two bytes.
            def together_record(set)
              gaps = set.groups.each_index.to_a - group_numbers(set)
              alone = group_numbers(set).reject { |number| set.together.any? { |list| list.include?(number) } }
              lists = (set.together + alone.map { |number| [number] }).map { |list| list | gaps }
              slots = @group_slots.fetch(set.name).flat_map { |slot| little_endian(place_of(slot.wanted), 2) }
              [@group_slots.fetch(set.name).length, *slots, *little_endian(lists.length, 2),
               *lists.flat_map { |list| [list.length, *list] }]
            end

            # The number of +set+'s check, for the reader of a run it stops (GBC::Places#together_checks).
            def register_together_check(set)
              check = [set.name, group_numbers(set), @group_slots.fetch(set.name).map(&:shown)]
              @together_checks.index(check) || (@together_checks << check).length - 1
            end

            # The numbers of +set+'s groups: every number from nought up to its last, but a gap in its
            # numbering (IR::Nodes::PictureGroups#names_group?).
            def group_numbers(set) = set.groups.each_index.select { |number| set.names_group?(number) }

            # The sets that can have more than one group up at once, which are the ones whose groups
            # up together are asked about.
            def sets_of_many_slots = @picture_sets.each_value.select { |set| set.slots > 1 }

            # The number of the check +check+ asks, a new one if no other check asks it yet:
            # [sprite, set, its poses, the groups holding each, the numbers naming a group, the slots].
            def register_picture_check(check) = @picture_checks.index(check) || (@picture_checks << check).length - 1

            # The table of slots the blank walks (Runtime::PictureGroups), for a game with groups.
            def emit_group_slots(asm)
              return unless @art.groups?

              asm.label("game_group_slots")
              @art.group_rooms.each_value do |room|
                @group_slots.fetch(room.set.name).each do |slot|
                  Runtime::PictureGroups.emit_slot(asm, wanted: place_of(slot.wanted), up: place_of(slot.up),
                                                        said: place_of(slot.shown), tiles: "art_group_#{room.number}_tiles",
                                                        groups: "art_group_#{room.number}_groups",
                                                        count: room.set.groups.length)
                end
              end
              asm.data_words(0)
            end

            def build_name = "the Game Boy Color build"

            # --- refusals ---

            # THE SETS GIVEN TO `colors_in_use` HAVE TO FIT IN THE EIGHT. The lists a set names are
            # shown together, so each takes turns in a list of its own (IR::Nodes::ColorList
            # .shared_name), and the sprites of a scene and the sprites every scene shows are drawn
            # through as many of those as its biggest set has lists. More than eight of them cannot
            # all borrow one of the console's eight at once, and some of the set's things would be
            # drawn in another list's colours, so it is refused, naming that set.
            def refuse_lists_in_use_past_eight!
              @objects.each_value.map(&:scene).uniq.each do |scene|
                shared = @objects.each_value.select { |obj| obj.scene.nil? || obj.scene == scene }
                                 .flat_map { |obj| Array(obj.recolors).grep(Symbol) }
                                 .select { |name| Nodes::ColorList.shared?(name) }.uniq
                next if shared.length <= Art::PALETTES

                whose = scene ? "The sprites of the scene #{scene.inspect}" : "The game's sprites"
                raise LoweringError, "#{whose} draw with the sets given to `colors_in_use`, and the biggest set " \
                                     "needs #{shared.length} lists of colours at once. A Game Boy Color holds " \
                                     "#{Art::PALETTES} lists for sprites. The biggest set is " \
                                     "#{@color_lists.fetch(shared.first).busiest_set}. To fix this, give that " \
                                     "set #{Art::PALETTES} lists or fewer."
              end
            end

            # --- the screen ---

            # A screen drawn from tiles is what a Color has. A turning screen is shown as one that
            # does not turn (Console::ColorAnswers), which the interpreter shows the same way when it
            # plays the game for a Color. A painted screen is 360 tiles of the background's
            # (Runtime::Paint). A change between the two replaces the display (rt_screen), and
            # what every tiled screen shows is put up again then (Reference#put_up_always_up). A
            # tear-free screen is the same one page: a Color only ever shows a picture whole, and
            # the interpreter keeps one page for it too (Console::Description's painted_pages).
            def emit_screen(node)
              emit_screen_change(node.mode)
            end

            def emit_screen_change(mode)
              painted = mode == :bitmap
              runtime_call("rt_screen", [Build.int(painted ? Runtime::Paint::PAINTED : Runtime::Paint::TILED)])
              return emit_bends_shown(nil) if painted # a painted screen has no background to bend

              always = @handover.always_up
              return if always.map_choices.empty? && always.scenery.empty?

              unchanged = fresh("screen_unchanged")
              @asm.call("rt_test32")
              @asm.jump(:z, unchanged)
              always.map_choices.each do |var|
                load_constant(0)
                store(var)
              end
              always.scenery.each { |bg| background_put_up(bg) }
              @asm.label(unchanged)
            end

            # The scene's screen, then its scenery: what it shows goes up as it arrives, and what the
            # scene before it showed of its own comes down — leaving what every screen shows, or
            # nothing (Reference#take_over).
            def emit_scene_arrival(scene)
              # The map of the painted screen's squares this scene shows (GBC::SquareColors).
              runtime_call("rt_paint_map", [Build.int(@art.square_map_of(scene))]) if @art.square_maps.length > 1
              arrival = @handover.arrival(scene)
              screen = arrival_screen(arrival)
              emit_screen_change(screen)
              emit_tile_room(arrival_room(scene)) # its own tiles, before its grids name them
              emit_lend_scene(scene)
              arrival.scenery.each { |bg| emit_held_background_colors(bg) }
              arrival.map_choices.each do |var|
                load_constant(0)
                store(var)
              end
              # Tiles its scenery and its sprites paint from a list show the list as it is now, changed
              # or not.
              arrival.painted_pictures.each { |run| emit_run_copy(run) }
              # A status bar is the window, beside the one background: the scene's own goes up there,
              # and one every screen shows stays as it is, as the interpreter leaves it.
              emit_bar_off_unless_shown(arrival)
              arrival.scenery.select(&:bar?).each { |bar| bar_put_up(bar) }
              own = arrival.scenery.reject(&:bar?)
              scenery = own.empty? ? @handover.always_up.scenery.reject(&:bar?) : own
              if scenery.empty?
                emit_bends_shown(nil)
                return runtime_call("rt_background_put_up", [Build.int(0)])
              end

              scenery.each { |bg| background_put_up(bg) }
              painted = arrival.scenery.empty? ? @handover.always_up.painted_tiles : arrival.painted_tiles
              painted.each { |run| emit_run_copy(run) }
              # The sprites this pass placed, in front of the scenery the scene brought of its own,
              # on a screen drawn from tiles (Reference#redraw_sprites_over_arrived_scenery).
              @asm.call("rt_sprites_on") if arrival.scenery.any? && SceneHandover.tiles?(screen)
            end

            # In a game whose scenes number their own sprite lists (Art::TooManyLentLists), the lending
            # is told the arriving scene's: from here a number past the lists every scene keeps means
            # one of this scene's.
            def emit_lend_scene(scene)
              return unless @art.lists_by_scene?

              @asm.load(:hl, @art.lent_scene_label(scene))
              @asm.call("rt_lend_scene")
            end

            # A screen with no status bar has the window off, in a game with a bar somewhere; one
            # with a bar switches it on as the bar goes up.
            def emit_bar_off_unless_shown(arrival)
              return unless bar_rows
              return if (arrival.scenery + @handover.always_up.scenery).any?(&:bar?)

              @asm.call("rt_bar_off")
            end

            # The screen a scene arrives on (:bitmap, :tiled…): the one it names, or the one its
            # drawing is for.
            def arrival_screen(arrival) = arrival.screen ? arrival.screen.mode : Modes::SCREEN_OF_MODE.fetch(arrival.mode)

            # --- painting ---

            def emit_clear_screen(node) = runtime_call("rt_paint_clear", [ink(node.color)])

            # Reference#exec_inside: what the block paints is held to the edges, which are numbers
            # written in the program, and the area held to before is put back after it — a routine
            # with an area of its own can be called from inside another's. A program that paints
            # nothing has no area to hold.
            def emit_inside(node)
              return node.children.each { |child| statement(child) } unless @square_colors

              outer = keep_local(:area)
              edges = [node.x, node.y, node.x + node.w, node.y + node.h]
              limits = Runtime::Paint::WHOLE_SCREEN.values_at(2, 3, 2, 3)
              area = edges.zip(limits).each_with_index.sum { |(edge, limit), at| edge.clamp(0, limit) << (8 * at) }
              runtime_call("rt_paint_area", [Build.int(Int32.wrap(area))])
              store(outer)
              node.children.each { |child| statement(child) }
              runtime_call("rt_paint_area", [outer])
            end

            # Framebuffer#fill_rect: from the corner up to the corner past the far edge.
            def emit_fill_rect(node)
              runtime_call("rt_paint_rect", [node.x, node.y, Build.binop(:+, node.x, node.w),
                                                 Build.binop(:+, node.y, node.h), ink(node.color)])
            end

            def emit_pixel(node) = paint_bits(node.x, node.y, ink(node.color), [[0, 0]])

            # The pixels of a line of text are known when the game is built, so they are handed over
            # as a picture rather than worked out from the font as it runs (Reference#exec_draw_text).
            def emit_draw_text(node)
              points = node.fonts.get(node.font).enum_for(:each_pixel, node.text).to_a
              return if points.empty?

              color = node.picked ? picked_ink(node.showing, node.color, node.picked) : ink(node.color)
              paint_bits(node.x, node.y, color, points)
            end

            # Reference#exec_draw_digit: each digit's picture, the one the value names drawn; a value
            # outside 0..9 draws nothing.
            def emit_draw_digit(node)
              font = node.fonts.get(node.font)
              digit = keep_local(:digit)
              value(node.value)
              store(digit)
              (0..9).each do |d|
                points = font.enum_for(:each_pixel, d.to_s).to_a
                next if points.empty?

                other = fresh("not_digit")
                jump_unless(Build.binop(:==, Build.var_ref(digit), Build.int(d)), other)
                paint_bits(node.x, node.y, ink(node.color), points)
                @asm.label(other)
              end
            end

            # The call that paints +points+ (pairs across and down from (x, y)) in +color+, as a
            # picture of a bit a pixel (Runtime::Paint's rt_paint_bits): rows of bytes, the
            # leftmost pixel in the top bit, with a byte of nothing either side of each row. A
            # picture whose first pixel is not at its corner is drawn that much further on.
            #
            # A picture at a column written in the program is laid out already lined up with the
            # screen's tiles — moved right within its first byte by as much as it stands past a
            # multiple of eight — so the runtime has no shifting to do.
            def paint_bits(x, y, color, points)
              left = points.map(&:first).min
              top = points.map(&:last).min
              column = folded(x)
              lined_up = column ? (column + left) % 8 : 0
              width = points.map(&:first).max - left + 1 + lined_up
              height = points.map(&:last).max - top + 1
              stride = ((width + 7) / 8) + 2
              bytes = Array.new(stride * height, 0)
              points.each do |dx, dy|
                col = dx - left + lined_up
                bytes[((dy - top) * stride) + 1 + (col / 8)] |= 0x80 >> (col % 8)
              end
              runtime_call("rt_paint_bits", [moved(x, left - lined_up), moved(y, top), color,
                                                 BankedAddress.new(drawing_table("bits", 1, bytes, banked: true)), Build.int(stride),
                                                 Build.int(height)])
            end

            def moved(place, by) = by.zero? ? place : Build.binop(:+, place, Build.int(by))

            # Reference#blit_image: a picture with its top left at (x, y), its see-through pixels
            # leaving the screen as it was. A pixel of a painted screen is one of four colours, so
            # the picture goes down as one picture of a bit a pixel for each colour it draws.
            def emit_blit(node) = picture_put_down(picture_named(node.name), node.x, node.y)

            def picture_put_down(image, x, y)
              points = Hash.new { |by_color, color| by_color[color] = [] }
              (image.width * image.height).times do |at|
                points[image.color_at(at)] << at.divmod(image.width).reverse if image.drawn_at?(at)
              end
              points.each { |color, drawn| paint_bits(x, y, Build.int(@art.paint_place(color)), drawn) }
            end

            # Reference#exec_blit_pose: the one of the pictures the number names, and none for a
            # number outside them.
            def emit_blit_pose(node)
              which = keep_local(:pose)
              value(node.index)
              store(which)
              node.poses.each_with_index do |name, at|
                other = fresh("not_pose")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(at)), other)
                picture_put_down(picture_named(name), node.x, node.y)
                @asm.label(other)
              end
            end

            # Reference#exec_draw_column_at: one column of a picture stretched to a height worked out
            # as the game runs. What is drawn is handed over in numbers the program keeps once
            # (COLUMN), the height first — a height of nought or less draws nothing, and the others
            # are not worked out — and the picture's own routine walks it (#emit_column_routines).
            def emit_draw_column_at(node)
              column = column_numbers
              label = @column_routines[node.name] ||= "column of #{node.name}"
              value(node.height)
              store(column.fetch(:height))
              done = fresh("no_height")
              jump_unless(Build.binop(:>, Build.var_ref(column.fetch(:height)), Build.int(0)), done)
              %i[slice x top].each do |what|
                value(node.public_send(what))
                store(column.fetch(what))
              end
              load_constant(node.width || 1)
              store(column.fetch(:width))
              call_routine(label)
              @asm.label(done)
            end

            def column_numbers = @column_numbers

            # The numbers a column is handed over in, kept before any routine is made — not the first
            # time one is drawn, which may be in code made only to be measured.
            def keep_column_numbers
              return unless @reachable.any? { |node| node.kind == :draw_column_at }

              @column_numbers = COLUMN.to_h { |what| [what, keep_local(:"column_#{what}")] }
            end

            # The routine that draws a column of each picture drawn so: walked down the screen a row
            # at a time, each row the picture's row the step in 65536ths lands it on, painted across
            # the strip's width, a see-through one left as it was. Only the rows on the screen are
            # walked.
            def column_sections
              @column_routines.map do |name, label|
                image = picture_named(name)
                places = Array.new(image.width * image.height) do |at|
                  image.drawn_at?(at) ? @art.paint_place(image.color_at(at)) : -1
                end
                table = drawing_table("column_places", 2, places)
                routine_section(label, [], routine: "#{name.inspect} drawn a column at a time") { emit_column_walk(image, table) }
              end
            end

            def emit_column_walk(image, table)
              height, x, top, width = column_numbers.values_at(:height, :x, :top, :width).map { |name| Build.var_ref(name) }
              slice, step, row, last, place = %i[slice step row last place].map { |what| keep_local(what) }
              fixed = Build.int(Reference::FIXED)
              value(Build.clamped(Build.var_ref(column_numbers.fetch(:slice)), Build.int(0), Build.int(image.width - 1)))
              store(slice)
              value(Build.binop(:/, Build.int(image.height << Reference::FIXED), height))
              store(step)
              value(Build.clamped(Build.neg(top), Build.int(0), Build.int(Int32::MAX)))
              store(row)
              value(Build.clamped(height, Build.int(Int32::MIN), Build.binop(:-, Build.int(Console::GBCHardware::SCREEN_HEIGHT), top)))
              store(last)
              walk = fresh("row")
              done = fresh("rows_done")
              @asm.label(walk)
              jump_unless(Build.binop(:<, Build.var_ref(row), Build.var_ref(last)), done)
              source = Build.clamped(Build.binop(:>>, Build.binop(:*, Build.var_ref(row), Build.var_ref(step)), fixed),
                                     Build.int(0), Build.int(image.height - 1))
              value(Entry.new(table, 2, true, Build.binop(:+, Build.binop(:*, source, Build.int(image.width)), Build.var_ref(slice))))
              store(place)
              see_through = fresh("see_through")
              jump_unless(Build.binop(:!=, Build.var_ref(place), Build.int(-1)), see_through)
              down = Build.binop(:+, top, Build.var_ref(row))
              runtime_call("rt_paint_rect", [x, down, Build.binop(:+, x, width), Build.binop(:+, down, Build.int(1)),
                                                 Build.var_ref(place)])
              @asm.label(see_through)
              add_in_place(place_of(row), 1)
              @asm.jump(walk)
              @asm.label(done)
            end

            # Reference#exec_save_region and #exec_restore_region: a patch of the picture kept in the
            # memory set aside for it, and painted back (Runtime::Paint's rt_paint_save and
            # rt_paint_restore).
            def emit_save_region(node) = patch_call("rt_paint_save", node)
            def emit_restore_region(node) = patch_call("rt_paint_restore", node)

            def patch_call(routine, node)
              buffer = @patches.fetch(node.buffer) { raise LoweringError, "backing buffer #{node.buffer.inspect} is used and never declared" }
              runtime_call(routine, [Build.int(@patch_places.fetch(node.buffer)), Build.int(buffer.width), Build.int(buffer.height),
                                     node.x, node.y])
            end

            # The memory each patch is kept in, a byte a pixel after a header's room (the runtime
            # takes its patches as it takes a list's storage), starting cleared: nothing kept.
            def keep_patches
              @patch_places = @patches.values.to_h do |buffer|
                [buffer.name, @memory.reserve("the patch #{buffer.name.inspect}", Runtime::Lists::HEADER + (buffer.width * buffer.height))]
              end
            end

            # The place a painted colour is kept at (GBC::Art#paint_place).
            def ink(name) = Build.int(@art.paint_place(Graphics::Color.resolve(name)))

            # +picked+ while +showing+ is not nought, +color+ otherwise.
            def picked_ink(showing, color, picked)
              plain = @art.paint_place(Graphics::Color.resolve(color))
              other = @art.paint_place(Graphics::Color.resolve(picked))
              Build.binop(:+, Build.int(plain), Build.binop(:*, Build.binop(:!=, showing, Build.int(0)), Build.int(other - plain)))
            end

            # --- backgrounds ---

            # Reference#exec_background: a scene's own scenery goes up as the scene arrives, not here;
            # any other is put up each time this runs. On a painted screen it is painted into the
            # picture here instead, as the interpreter stamps it (#paint_background).
            def emit_background(node)
              return paint_background(node) if painted_screen_for?(node)

              background_put_up(node) unless @handover.on_arrival?(node)
            end

            # Whether a background is declared where the screen is painted: its scene's screen, or the
            # game's for one in no scene.
            def painted_screen_for?(bg) = Modes::SCREEN_OF_MODE.fetch(Modes.resolve(@program).mode_of(bg.scene)) == :bitmap

            # Reference#stamp_background on a painted screen: each cell's tile painted where the cell
            # is, its see-through pixels leaving what is there, and nothing past the screen's edge.
            def paint_background(bg)
              width = Console::GBCHardware::SCREEN_WIDTH
              height = Console::GBCHardware::SCREEN_HEIGHT
              bg.map.each_with_index do |row, r|
                Array(row).each_with_index do |tile, c|
                  x = c * bg.tile_w
                  y = r * bg.tile_h
                  next if tile.nil? || tile.negative? || x >= width || y >= height

                  image = Assets::Image.of(@pictures.fetch(bg.tiles.fetch(tile)))
                  points = Hash.new { |by_color, color| by_color[color] = [] }
                  (image.width * image.height).times do |at|
                    points[image.color_at(at)] << at.divmod(image.width).reverse unless image.tile_see_through_at?(at)
                  end
                  points.each { |color, drawn| paint_bits(Build.int(x), Build.int(y), Build.int(@art.paint_place(color)), drawn) }
                end
              end
            end

            # A background goes up as its grid, or as a map bigger than the grid (Runtime::BigMaps),
            # unscrolled every time, even when its grid is up already: a background put up again
            # on every pass, after the game has said where its view sits, shows from its corner on
            # every frame (Runtime::Picture's rt_background_put_up_unscrolled).
            def background_put_up(bg)
              return bar_put_up(bg) if bg.bar?

              emit_tile_room(tile_room(bg)) if bg.several_sets? # up as declared: its first area

              emit_bends_shown(bg)
              big?(bg) ? big_put_up(bg, 0, "rt_big_put_up") : runtime_call("rt_background_put_up_unscrolled", [Build.int(grid_of(bg))])
              note_put_up(@put_up_this_pass)
            end

            # Whether any of a background's maps is bigger than the Color's grid of 32×32 cells.
            def big?(bg)
              bg.every_map.any? do |map|
                cols, rows = TileMap.size_of(map)
                cols > Art::GRID_CELLS || rows > Art::GRID_CELLS
              end
            end

            # A background's map number +which+ kept whole, for a background one of whose maps is
            # bigger than the grid (GBC::Art#big_map): every map of it is kept that way, so each stops
            # at its own edge.
            def big_map_of(bg, which = 0)
              @big_maps ||= {}
              @big_maps[[bg, which]] ||= begin
                refuse_background!(bg)
                @art.big_map(bg.every_map.fetch(which).map do |row|
                  Array(row).map { |tile| tile.nil? || tile.negative? ? nil : background_tile_named(bg.tiles.fetch(tile), bg, tile_room(bg, which)) }
                end)
              end
            end

            # A STATUS BAR goes up into the console's window (Runtime::Picture#emit_bar), at the row
            # it was declared with until it is placed (Reference#bar_top_shown).
            def bar_put_up(bar)
              top = bar.bar_top.clamp(0, Console::GBCHardware::SCREEN_HEIGHT)
              runtime_call("rt_bar_put_up", [Build.int(grid_of(bar)), Build.int(top)])
              note_put_up(@bar_up_this_pass)
            end

            # Reference#exec_place_bar.
            def emit_place_bar(node)
              return unless declared_background!(node).bar? # one that is not a status bar has no top to place

              emit_unless_put_up(node, @bar_up_this_pass) { runtime_call("rt_place_bar", [node.top]) }
            end

            def emit_scroll_background(node)
              declared_background!(node)
              emit_unless_put_up(node, @put_up_this_pass) { runtime_call("rt_background_scroll", [node.x, node.y]) }
            end

            def declared_background!(node)
              @backgrounds.fetch(node.name) { raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" }
            end

            # A LINE THAT CHANGES A BACKGROUND BY NAME, for a name declared in several scenes: each
            # declaration has tiles, maps and colours of its own, and the line means the one on the
            # screen up (Reference#background_up). So the line's code is written once for each
            # declaration, each part run only while its scene is the one running — a compare a
            # declaration. Every other background gets its one declaration and no compare.
            def each_declaration(node)
              declared = declarations_in_several_scenes[node.name]
              return yield(declared_background!(node)) unless declared

              declared.each do |bg|
                next yield(bg) unless bg.scene
                next unless @scenes.key?(bg.scene) # a scene nothing hands over to is never up

                other = fresh("not_this_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(@scenes.fetch(bg.scene))), other)
                yield bg
                @asm.label(other)
              end
            end

            # Each background name declared in several scenes, and its declarations, worked out once.
            def declarations_in_several_scenes
              @declarations_in_several_scenes ||= begin
                backgrounds = @program.walk.select { |node| node.kind == :background }
                Stacking.names_in_several_scenes(backgrounds).to_h do |name|
                  [name, backgrounds.select { |bg| bg.name == name }]
                end
              end
            end

            # Reference#exec_show_map: the background handed map number +which+ whole, as it was
            # declared — its grid put up — and a number naming no map leaves it as it is. A number
            # written in the program is looked up here; one worked out as the game runs, in a table
            # of the maps' grids.
            #
            # A background bigger than the grid hands over its map kept whole (#big_map_of) and keeps
            # its view where it is (Runtime::BigMaps's rt_big_show).
            def emit_show_map(node) = each_declaration(node) { |bg| emit_show_map_for_declaration(bg, node) }

            def emit_show_map_for_declaration(bg, node)
              return emit_show_changed_big_map(bg, node) if big?(bg) && changed_big?(bg)

              emit_area_room(bg, node.which) if bg.several_sets? && @tile_rooms

              routine = big?(bg) ? "rt_big_show" : "rt_background_put_up"
              grids = bg.every_map.each_index.map { |which| big?(bg) ? big_map_of(bg, which) : grid_of(bg, which) }
              known = folded(node.which)
              return (runtime_call(routine, [Build.int(grids.fetch(known))]) if known.between?(0, grids.length - 1)) if known

              table = drawing_table("map_grids", 1, grids)
              past = fresh("past_the_map")
              value(node.which)
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, past) # below nought, or far past the maps
              @asm.load(:a, :e)
              @asm.cp_a(grids.length)
              @asm.jump(:nc, past)
              @asm.load(:hl, table)
              @asm.load(:d, 0)
              @asm.add_hl(:de)
              @asm.load(:a, [:hl])
              @asm.load(:e, :a)
              2.times { @asm.push(:de) } # the grid's number, as a four-byte argument
              @asm.call(routine)
              @asm.add_sp(4)
              @asm.label(past)
            end

            # ...a big background the game changes: the map named copied in as declared and handed
            # over, by number, and a number naming none leaves it as it is.
            def emit_show_changed_big_map(bg, node)
              which = keep_local(:map)
              value(node.which)
              store(which)
              bg.every_map.each_index do |at|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(at)), other)
                big_put_up(bg, at, "rt_big_show")
                @asm.label(other)
              end
            end

            # Reference#exec_camera: the view moved over the painted picture. The picture is the
            # screen's size, the console's grid of tiles holding it with nothing past its edge, so
            # the grid is scrolled (Runtime::Picture's rt_background_scroll), and black shows past
            # the picture, as the interpreter shows it.
            def emit_camera(node) = runtime_call("rt_background_scroll", [node.x, node.y])

            # A BACKGROUND BENT ROW BY ROW (Reference#exec_scroll_rows): a standing declaration,
            # gathered up front. Its rows are worked out at every frame boundary (#emit_bends), and
            # shown while its background is up (#emit_bends_shown).
            def emit_scroll_rows(node) = declared_background!(node)

            # Reference#work_out_bends, where the pass's wait ends: every bend's, whichever
            # background is up, as the interpreter works every one out. Each row of the screen, its
            # number in the bend's variable, the bend's own steps, and how far along it sits kept in
            # the bend's table for the frame after (#bend_table); the first row of each bend, then
            # the rest of each; then the variable left past the last row. +painting+ is the
            # interpreter painting a game that never waits, row by row (Reference#bend_offset_at),
            # which leaves the variable at the last row.
            def emit_bends(painting: false)
              height = Console::GBCHardware::SCREEN_HEIGHT
              bends.each { |bend| emit_bend_rows(bend, 0...1) }
              bends.each do |bend|
                emit_bend_rows(bend, 1...height)
                statement(Build.set(bend.row, height - 1)) if painting
              end
            end

            # Rows +rows+ (a range short of its end) of +bend+: the first in its variable, its
            # steps, the row kept, and on to the next until the last, leaving the variable at the end.
            def emit_bend_rows(bend, rows)
              row = fresh("bend_row")
              statement(Build.set(bend.row, rows.begin))
              @asm.label(row)
              bend.children.each { |child| statement(child) }
              emit_store_row_offset(bend)
              statement(Build.add(bend.row, 1))
              return if rows.size == 1

              value(bend.row) # rows from nought to the last, so the low byte is all there is to ask
              @asm.load(:a, :e)
              @asm.cp_a(rows.end)
              @asm.jump(:c, row)
            end

            # The game's bends, one for each background bent (Reference#collect_definitions): the
            # last a background is given, in the order the backgrounds were first bent.
            def bends
              @bends ||= @program.walk.select { |node| node.kind == :scroll_rows }.group_by(&:name).map { |_, said| said.last }
            end

            # Where a bend's rows are kept as a pass works them out: a byte for each row of the screen.
            def bend_table(bend)
              @bend_tables ||= {}
              @bend_tables[bend.name] ||= @memory.reserve("the bend of #{bend.name.inspect}", Console::GBCHardware::SCREEN_HEIGHT)
            end

            # The row in the bend's variable kept in its table: the low byte of how far along.
            def emit_store_row_offset(bend)
              value(bend.row)
              @asm.load(:a, :e)
              @asm.push(:af)
              value(bend.offset)
              @asm.pop(:af)
              @asm.load(:l, :a)
              @asm.load(:h, 0)
              @asm.load(:bc, bend_table(bend))
              @asm.add_hl(:bc)
              @asm.load([:hl], :e)
            end

            # Reference#bend_offset_at: a background is drawn with its own bend, or flat when it has
            # none, so the background going up says which table the rows are shown from
            # (Runtime::Picture's rt_bends_on), or that none is (rt_bends_off) — +bg+ nil for no
            # background at all. A game that bends nothing says neither.
            def emit_bends_shown(bg)
              return if bends.empty?

              bend = bg && bends.find { |said| said.name == bg.name }
              return @asm.call("rt_bends_off") unless bend

              @asm.load(:hl, bend_table(bend))
              @asm.call("rt_bends_on")
            end

            # Reference#exec_set_tile: one cell of the background given another of its tiles — or
            # none, the backdrop — written into the console's grid (Runtime::Picture's
            # rt_background_cell), and a cell off the map changing nothing. Its maps must be one size,
            # so the edge is the same whichever is showing.
            #
            # A big map's cell is changed where the map is kept while it is up (Runtime::BigMaps's
            # rt_big_set).
            def emit_set_tile(node)
              each_declaration(node) do |bg|
                # A tile only another scene's declaration of this name has, from a line written for
                # that scene: this declaration's part of the line writes nothing.
                emit_set_tile_for_declaration(bg, node) if node.tile.nil? || node.tile.negative? || node.tile < bg.tiles.length
              end
            end

            def emit_set_tile_for_declaration(bg, node)
              tile = node.tile
              number, palette = tile.nil? || tile.negative? ? [0, 0] : background_tile_named(bg.tiles.fetch(tile), bg, tile_room(bg))
              colours = palette | (number >= 256 ? Console::GBCHardware::ATTR_TILE_BANK : 0)
              cell = Build.int((number & 0xFF) | (colours << 8))
              return runtime_call("rt_big_set", [node.col, node.row, cell]) if big?(bg)

              refuse_background!(bg, as_grid: true)
              cols, rows = map_size_of(bg)
              routine = bg.bar? ? "rt_bar_cell" : "rt_background_cell" # a status bar's is in the window's grid
              row = folded(node.row)
              if row && byte_valued?(node.col)
                grid = bg.bar? ? Console::GBCHardware::TILE_MAP1 : Console::GBCHardware::TILE_MAP0
                return emit_cell_at_known_row(routine, grid, node.col, row, [cols, rows], cell.value)
              end

              emit_cell_numbers(node.col, node.row, cols | (rows << 8), cell.value)
              @asm.call("#{routine}_taken")
            end

            # A cell whose row and tile are written in the program and whose column can only be a
            # byte — a status bar's text, written a cell at a time — has its place worked out here:
            # the row's start in the grid, 32 cells a row, is known now, so only the column is
            # added as the game runs, and the routine is handed the place and the cell. A row off
            # the map writes nothing, and so does a column off it.
            def emit_cell_at_known_row(routine, grid, col, row, (cols, rows), cell)
              return unless row.between?(0, rows - 1)

              off = fresh("cell_off_the_map")
              emit_low_byte_in_a(col)
              @asm.cp_a(cols)
              @asm.jump_relative(:nc, off)
              @asm.load(:e, :a)
              @asm.load(:d, 0)
              @asm.load(:hl, grid + (row * 32))
              @asm.add_hl(:de)
              @asm.load(:bc, cell)
              @asm.call("#{routine}_at_hl")
              @asm.label(off)
            end

            # A cell's four numbers written where rt_background_cell reads them once it has taken
            # them off the stack, rather than pushed for it to copy: a status bar's text is written
            # a cell at a time, many cells a pass. The column and the row are written whole, the
            # row first if it is worked out, since working one out may use the same quick memory;
            # of the map's size and the cell, numbers written in the program, only the two low
            # bytes are read.
            def emit_cell_numbers(col, row, size, cell)
              at = ->(i) { Runtime::Calls.arg(@memory, i, 4) }
              row_known = folded(row)
              unless row_known
                value(row)
                @asm.push(:bc)
                @asm.push(:de)
              end
              if byte_valued?(col)
                # A column that can only be a byte: that byte, and nought above it.
                emit_low_byte_in_a(col)
                @asm.load_high(at.call(0), :a)
                emit_number_at_high(at.call(0) + 1, 0, 3)
              else
                value(col)
                emit_bcde_at_high(at.call(0))
              end
              if row_known
                emit_number_at_high(at.call(1), row_known, 4)
              else
                @asm.pop(:de)
                @asm.pop(:bc)
                emit_bcde_at_high(at.call(1))
              end
              emit_number_at_high(at.call(2), size, 2)
              emit_number_at_high(at.call(3), cell, 2)
            end

            # BCDE's four bytes into quick memory from +address+ up, lowest first.
            def emit_bcde_at_high(address)
              BCDE_LOW_FIRST.each_with_index do |register, i|
                @asm.load(:a, register)
                @asm.load_high(address + i, :a)
              end
            end

            # The low +bytes+ bytes of +number+, written in the program, into quick memory from
            # +address+ up; A is loaded only when the byte differs from the one before.
            def emit_number_at_high(address, number, bytes)
              held = nil
              bytes.times do |i|
                byte = (number >> (8 * i)) & 0xFF
                (byte.zero? ? @asm.xor_a(:a) : @asm.load(:a, byte)) unless byte == held
                held = byte
                @asm.load_high(address + i, :a)
              end
            end

            # Whether the game changes a big background's cells as it runs, so it is kept in work
            # memory while it is up.
            def changed_big?(bg) = @reachable.any? { |node| node.kind == :set_tile && node.name == bg.name }

            # A big background put up — or handed map number +which+ (+routine+ rt_big_show) — from its
            # map kept whole; one the game changes copied into work memory first.
            def big_put_up(bg, which, routine)
              return runtime_call(routine, [Build.int(big_map_of(bg, which))]) unless changed_big?(bg)

              runtime_call("rt_big_copy_in", [Build.int(big_map_of(bg, which)), Build.int(changed_big_place(bg))])
              cols, rows = TileMap.size_of(bg.every_map.fetch(which))
              runtime_call(routine, [Build.int(@art.big_map_in_memory(cols, rows, changed_big_place(bg)))])
            end

            # Where a big background the game changes is kept: room for the biggest of its maps.
            def changed_big_place(bg)
              @changed_big_places ||= {}
              @changed_big_places[bg] ||= begin
                bytes = bg.every_map.map { |map| TileMap.size_of(map).reduce(:*) * 2 }.max
                @memory.reserve("the changed map of #{bg.name.inspect}", bytes)
              end
            end

            # Room for every palette's colours as drawn now, in a game that draws a background in
            # other colours anywhere a run can reach, whose sprites' lists borrow the eight, or whose
            # screens bring their own colours in.
            def keep_drawn_palettes
              return unless @art.lends? || @art.room_colors? || @reachable.any? { |node| node.kind == :background_colors }

              @drawn_palettes = @memory.reserve("the colours drawn now", 128)
            end

            # The copy of the grid a map bigger than it is worked out into — at an address that is a
            # multiple of 16, which the console's copying reads from — and the list for the blank.
            def keep_big_map_places
              return unless @backgrounds.each_value.any? { |bg| big?(bg) }

              copy = @memory.reserve("the copy of a big map's grid", Runtime::BigMaps::BUFFER_BYTES + 15)
              @big_map_places = [(copy + 15) & ~15, @memory.reserve("the cells for the blank", Runtime::BigMaps::STAGED_BYTES)]
            end

            # Reference#exec_background_colors: the background's tiles drawn from another of its lists
            # of colours, by a number the game works out — or its own, for a number naming none. The
            # Color draws a tile in one of its palettes, so the background's palettes are written
            # with the colours its tiles show now (#background_colors_table), into the colours the
            # pictures are drawn in now, and the fade in force moves them from there.
            #
            # In a game whose screens bring their own colours in, a scene's background keeps the
            # number it was told, since its scene's colours come in again each time it arrives
            # (#emit_held_background_colors).
            def emit_background_colors(node)
              which = node.which
              held = @background_colors_held[node.name]
              if held
                statement(Build.set(held, which))
                which = Build.var_ref(held)
              end
              each_declaration(node) { |bg| emit_background_colors_for_declaration(bg, which) }
            end

            # Each background a scene of a game whose screens bring their own colours in shows and
            # draws with other colours: the number it was told last, by its name, from power-on the
            # one naming none — as the interpreter keeps it by name (Reference @bg_colors).
            def keep_background_colors_held
              recolored = @art.room_colors? ? recolored_scenery.select(&:scene) : []
              @background_colors_held = recolored.map(&:name).uniq.to_h do |name|
                [name, keep_local(:"colors_of_#{name}", start: Build::NO_RECOLOR)]
              end
            end

            # Where each area brings its own colours in, one area's list of colours can be in a palette
            # another area's list is in, so a background that walks between areas cannot be drawn
            # with other colours.
            def refuse_walking_recolor!(bg)
              return unless bg.several_sets? && @art.room_colors?

              raise LoweringError, "the background #{bg.name.inspect} walks between areas and is told `draw_with`. " \
                                   "This game uses more lists of colours than a Game Boy Color holds at once, so each " \
                                   "area brings its own lists in. Then #{build_name} cannot draw such a background " \
                                   "with other colours. To fix this, remove `draw_with`, or use fewer lists of colours."
            end

            # The colours +bg+ was told to draw with, said again as its scene's own colours arrive.
            def emit_held_background_colors(bg)
              held = @background_colors_held[bg.name]
              emit_background_colors_for_declaration(bg, Build.var_ref(held)) if held
            end

            # In a game too big for the part of the cartridge always in view, the tables are kept in
            # its banks (GBC#build_cartridge), each table's bank in C beside its place in HL, and
            # rt_background_colors_far puts that bank in view to read it.
            def emit_background_colors_for_declaration(bg, which)
              refuse_walking_recolor!(bg)
              steps = Array(bg.recolors)
              banked = @bank_background_colors
              own = drawing_table("background_colors", 1, background_colors_table(bg, nil), banked: banked)
              tables = steps.each_index.map do |step|
                drawing_table("background_colors", 1, background_colors_table(bg, step), banked: banked)
              end
              chosen = fresh("background_colors_chosen")
              own_chosen = fresh("background_colors_own") if banked
              value(which)
              # The bank goes in C, which holds part of the number until it is tested, so a banked
              # table's own is pointed at after the tests, and one in view before them.
              emit_colors_address(own, false) unless banked
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, banked ? own_chosen : chosen) # below nought, or far past the lists
              @asm.load(:a, :e)
              tables.each_with_index do |table, step|
                other = fresh("not_colors_#{step}")
                @asm.cp_a(step)
                @asm.jump(:nz, other)
                emit_colors_address(table, banked)
                @asm.jump(chosen)
                @asm.label(other)
              end
              if banked
                @asm.label(own_chosen)
                emit_colors_address(own, banked)
              end
              @asm.label(chosen)
              @asm.call(banked ? "rt_background_colors_far" : "rt_background_colors")
            end

            # HL at a table of colours, and C at its bank where it is +banked+. A and the flags are kept.
            def emit_colors_address(table, banked)
              @asm.load(:hl, table)
              @asm.load_bank_of(:c, table) if banked
            end

            # The palettes a background's tiles are drawn in with its lists of colours number +step+
            # (nil for its own), as rt_background_colors reads them: how many, then each palette's
            # number and its four colours. Each tile's list swaps its colours by place
            # (Assets::Recolor), and two tiles are drawn from one palette only when they show the same
            # colours with every list (#recolor_steps_of). Where each screen brings its own tiles in,
            # the tiles counted are the ones the background shows, as its screen's tiles and colours
            # were planned (#plan_tile_rooms).
            def background_colors_table(bg, step)
              swaps = step && swaps_for(bg, step)
              palettes = {}
              (@tile_rooms ? tiles_shown(bg) : bg.tiles.compact.uniq).each do |name|
                _, palette = background_tile_named(name, bg, tile_room(bg))
                colors = tile_colors_with(name, swaps)
                if palettes.key?(palette) && palettes[palette] != colors
                  raise LoweringError, "#{build_name} drew two tiles of the background #{bg.name.inspect} from one list " \
                                       "of colours, and the two show other colours. This is a fault in the build, not " \
                                       "in the game."
                end

                palettes[palette] = colors
              end
              [palettes.size, *palettes.flat_map { |palette, colors| [palette, *colors.flat_map { |c| [c & 0xFF, c >> 8] }] }]
            end

            # The four colours tile +name+'s palette holds when drawn with +swaps+ (the list each of
            # the layer's own lists is drawn with, or nil for its own): the backdrop, then the colour
            # each of its own shows. A tile drawn by place from its list (GBC::Art#list_order, and
            # GBC::Art#drawn_places for one drawn with other lists) has a colour of the palette for
            # each place instead, so it swaps place for place.
            def tile_colors_with(name, swaps)
              run = run_painting(name)
              if run
                swapped = swaps && swaps[run.list_drawn_from]
                own = run.colors.drop(1).first(Art::OWN_COLORS)
                shown = own.each_with_index.map { |color, i| swapped && swapped[i + 1] || color }
                return padded_colors(shown)
              end

              image = Assets::Image.of(@pictures.fetch(name))
              swapped = swaps && swaps[image.list_drawn_from]
              order = @art.list_order(image)
              if order
                shown = order.map { |place| ((swapped && swapped[place]) || image.colors[place]) & 0x7FFF }
                return shown.fill(Art::BACKDROP, shown.length...Art::PLACES)
              end

              placed = @art.drawn_places(image)
              return @art.placed_colors(image, placed) { |place| (swapped && swapped[place]) || image.colors[place] } if placed

              drawn = @art.tile_colors(image)
              return padded_colors(drawn) unless swapped

              recolor = Assets::Recolor.of(image, swapped)
              shown = drawn.map do |color|
                at = (0...64).select { |i| !image.tile_see_through_at?(i) && (image.color_at(i) & 0x7FFF) == color }
                ways = at.map { |i| recolor.color_for(i, image.color_at(i)) & 0x7FFF }.uniq
                # Only a tile that draws more places than its palette holds gets here
                # (GBC::Art#drawn_places): each of its places is a colour of its own then.
                refuse_too_many_places!(name, image) unless ways.one?

                ways.first
              end
              padded_colors(shown)
            end

            def refuse_too_many_places!(name, image)
              drawn = (0...64).reject { |i| image.tile_see_through_at?(i) }.map { |i| image.place_at(i) }.uniq.length
              holds = @art.see_through_tile?(image) ? "#{Art::OWN_COLORS} colours and the backdrop" : "#{Art::PLACES} colours"
              raise LoweringError, "the tile #{name.inspect} draws #{drawn} places of its list. With another list of " \
                                   "colours, each place shows a colour of its own. A Game Boy Color tile holds #{holds}. " \
                                   "To fix this, draw the tile from fewer places."
            end

            # The colours tile +name+'s palette shows with each list of colours background +bg+ is
            # drawn with, in order: what its palette is written with as the game runs
            # (GBC::Art#background_tile), with +bg+'s name, since the interpreter keeps the list each
            # background is drawn with by its name and two can be told theirs at different times.
            # Nil for a background never drawn with other colours, and for a tile none of its lists
            # changes, so a tile it shows beside one that is has a palette apart only where the two
            # show it differently — as the interpreter swaps each background's colours on its own.
            def recolor_steps_of(name, bg)
              return nil if Array(bg.recolors).empty?

              @recolor_steps ||= {}
              return @recolor_steps[[name, bg]] if @recolor_steps.key?([name, bg])

              own = tile_colors_with(name, nil)
              steps = bg.recolors.each_index.map { |step| tile_colors_with(name, swaps_for(bg, step)) }
              @recolor_steps[[name, bg]] = steps.all?(own) ? nil : [bg.name, steps]
            end

            # The backgrounds drawn with other lists of colours.
            def recolored_scenery = @recolored_scenery ||= tiled_scenery.reject { |bg| Array(bg.recolors).empty? }

            # Each of +bg+'s own lists to the list it is drawn with at its step +step+.
            def swaps_for(bg, step) = bg.list_swaps(step)

            def padded_colors(colors) = [@art.backdrop, *colors.map { |color| color & 0x7FFF }].fill(Art::BACKDROP, colors.length + 1...Art::PLACES)

            def map_size_of(bg)
              sizes = bg.every_map.map { |map| TileMap.size_of(map) }.uniq
              return sizes.first if sizes.one?

              raise LoweringError, "the background #{bg.name.inspect} has maps of different sizes and a cell changed with " \
                                   "`set_tile`, which #{build_name} cannot make yet."
            end

            # A background's cells as the Color's grid of 32×32 holds them, for its map number
            # +which+: each cell's tile and palette, and nothing — the backdrop — where the map has
            # no tile or does not reach.
            def grid_of(bg, which = 0)
              @grids[[bg, which]] ||= begin
                refuse_background!(bg, as_grid: true)
                map = bg.every_map.fetch(which)
                cells = Array.new(Art::GRID_CELLS) do |row|
                  Array.new(Art::GRID_CELLS) do |col|
                    tile = map[row] && map[row][col]
                    next nil if tile.nil? || tile.negative?

                    background_tile_named(bg.tiles.fetch(tile), bg, tile_room(bg, which))
                  end
                end
                @art.grid(cells)
              end
            end

            # What a background has that this build does not make yet: tiles other than 8×8, and — as a
            # grid, for a step that changes the grid (`set_tile`, `show_map`) — a map bigger than it.
            def refuse_background!(bg, as_grid: false)
              sizes = bg.every_map.map { |map| TileMap.size_of(map) }
              cols, rows = sizes.max
              what = if bg.tile_w != 8 || bg.tile_h != 8 then "tiles of #{bg.tile_w}×#{bg.tile_h}"
                     elsif as_grid && big?(bg) then "a map of #{cols}×#{rows} cells changed as the game runs"
                     end
              return unless what

              raise LoweringError, "the background #{bg.name.inspect} has #{what}, which #{build_name} cannot make yet."
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, written into the console's
            # sprite table front-most first — the order the Color draws them in, where the
            # interpreter paints the back-most first.
            #
            # A run the game puts in order as it runs (`draw_in_order`, Reference#names_in_draw_order)
            # stands at its place among the rest, and its sprites are placed in the order its list
            # holds them, read from the front: each sprite's placing is a routine of the frame's own,
            # called by the number the list holds.
            def emit_present_objects(node)
              object = ->(name) { @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" } }
              changing = node.names.map(&object).select { |obj| Stacking.levels_of(@stacking.depths, obj).uniq.length > 1 }
              return emit_layer_changing_sprites(node, node.names.map(&object)) unless changing.empty?

              items = present_items(node).map { |item| item.is_a?(Build::DrawOrder) ? item : object.call(item) }
              front_first = items.each_with_index.sort_by { |item, at| [item_level(item, object), at] }.map(&:first).reverse
              placings = {}
              emit_groups_wanted
              emit_refuse_groups_not_together
              @asm.call("rt_sprites_begin")
              unless_sprites_hidden do
                front_first.each do |item|
                  next emit_placing_unless_unchanged(item) unless item.is_a?(Build::DrawOrder)

                  item.objects.each { |name| placings[name] ||= fresh("place_sprite") }
                  emit_ordered_run(item, placings)
                end
              end
              @asm.call("rt_sprites_end")
              return if placings.empty?

              past = fresh("past_the_placings")
              @asm.jump(past)
              placings.each do |name, label|
                @asm.label(label)
                sprite_placement(object.call(name))
                @asm.ret
              end
              @asm.label(past)
            end

            # A FRAME WITH SPRITES THAT CHANGE LAYER as the game runs (`put_in_layer`,
            # Reference#object_level): every depth any of them can be at, front-most first, and at
            # each, every sprite that can be there, placed when the layer it is in now is that one —
            # so a sprite is placed once, among the sprites of its layer now, behind the background
            # or not as that layer is.
            def emit_layer_changing_sprites(node, objects)
              unless Array(node.orders).empty?
                raise LoweringError, "this program puts sprites in order as the game runs (`draw_in_order`) and moves a " \
                                     "sprite to another layer, which #{build_name} cannot make yet."
              end

              emit_groups_wanted
              emit_refuse_groups_not_together
              @asm.call("rt_sprites_begin")
              unless_sprites_hidden do
                objects.flat_map { |obj| Stacking.levels_of(@stacking.depths, obj) }.uniq.sort.reverse_each do |level|
                  objects.reverse_each do |obj|
                    there = at_level(obj, level)
                    next if there.nil?
                    next sprite_placement(obj, level) if there == true

                    elsewhere = fresh("sprite_elsewhere")
                    jump_unless(there, elsewhere)
                    sprite_placement(obj, level)
                    @asm.label(elsewhere)
                  end
                end
              end
              @asm.call("rt_sprites_end")
            end

            # A FRAME WITHOUT SPRITES (`hide_sprites`, Reference#exec_hide_sprites). The pass that
            # asks only notes it; the next placing of the frame's sprites places none and forgets
            # it was asked. rt_sprites_end then moves every entry of the sprite table above the
            # screen, so nothing of any sprite shows on that frame, and the placing after puts each
            # one back where it is by then. The game's own numbers for each sprite are not
            # touched, so nothing has to be put back. A game that never asks emits nothing for it.
            #
            # In a game whose sprites borrow the eight lists, the empty pass counts as a pass, so on
            # the one after every list looks free and a sprite may borrow one another still holds.
            # That costs nothing in the picture: the one it was taken from borrows another in turn,
            # and each borrowing copies its colours in, so every sprite is drawn in its own. Only a
            # pass wearing more than eight lists at once misses one, as it would without the gap.
            # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME
            # (Reference#put_up_background), and the place the game keeps for its view — or the top
            # it keeps for a status bar — is written at the end of the pass (IR::Frames
            # .loop_in_console_order), after the put-up. So a put-up notes itself for the rest of its
            # pass, and the write at the end of it leaves the background or bar where it was put up;
            # the wait forgets the note (#emit_corners_forgotten), and the next pass's write moves it.
            def keep_corner_notes
              placed = ->(kind) { @program.walk.any? { |node| node.kind == kind && placed_at_pass_end?(node) } }
              @put_up_this_pass = keep_local(:put_up_this_pass) if placed.call(:scroll_background)
              @bar_up_this_pass = keep_local(:bar_up_this_pass) if placed.call(:place_bar)
            end

            # +note+ (a local of #keep_corner_notes, or nil for none) set: the background or bar was
            # put up this pass.
            def note_put_up(note)
              statement(Build.set(note, 1)) if note
            end

            # The notes forgotten at a wait: the pass that put a background up has ended.
            def emit_corners_forgotten
              [@put_up_this_pass, @bar_up_this_pass].compact.each { |note| statement(Build.set(note, 0)) }
            end

            # +node+'s write, unless it is written at the end of a pass that put its background or bar
            # up (+note+, #keep_corner_notes).
            def emit_unless_put_up(node, note)
              return yield unless note && placed_at_pass_end?(node)

              held = fresh("held_at_corner")
              jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
              yield
              @asm.label(held)
            end

            def keep_sprites_hidden_flag
              @sprites_hidden = keep_local(:sprites_hidden) if @reachable.any? { |node| node.kind == :hide_sprites }
            end

            def emit_hide_sprites(_node)
              statement(Build.set(@sprites_hidden, 1))
            end

            # The sprites the block places, placed unless the pass before asked for a frame without them.
            def unless_sprites_hidden
              return yield unless @sprites_hidden

              shown = fresh("sprites_shown")
              placed = fresh("sprites_placed")
              jump_unless(Build.var_ref(@sprites_hidden), shown)
              statement(Build.set(@sprites_hidden, 0))
              if keeps_unchanged_sprites? # every entry moves: no sprite's is where it left it (Runtime::KeptSprites)
                @asm.load(:hl, @memory[Runtime::KeptSprites::ROUND])
                @asm.inc([:hl])
              end
              @asm.jump(placed)
              @asm.label(shown)
              yield
              @asm.label(placed)
            end

            # When a sprite is at depth +level+: always (true), never (nil), or a test of the number
            # that picks its layer — one naming a layer at that depth, or, for its own layer's depth,
            # one naming none of them.
            def at_level(obj, level)
              own = @stacking.depths[obj.name] == level
              layers = Array(obj.layers)
              return (own ? true : nil) if layers.empty?

              pick = Build.var_ref(obj.layer_pick)
              tests = layers.each_index.select { |i| @stacking.depths[Stacking.choice_name(obj, layers[i])] == level }
                            .map { |i| Build.binop(:==, pick, Build.int(i)) }
              if own
                tests << Build.binop(:or, Build.binop(:<, pick, Build.int(0)), Build.binop(:>=, pick, Build.int(layers.length)))
              end
              tests.reduce { |either, test| Build.binop(:or, either, test) }
            end

            # The frame's sprites back to front, each a name — or, for a run the game orders, the run.
            def present_items(node)
              Array(node.orders).reduce(node.names.dup) do |names, run|
                first = names.index(run.objects.first)
                names[0...first] + [run] + names[(first + run.objects.length)..]
              end
            end

            # How deep an item sits: a sprite's level, and a run's, which its sprites share.
            def item_level(item, object)
              return sprite_level(item) unless item.is_a?(Build::DrawOrder)

              levels = item.objects.map { |name| sprite_level(object.call(name)) }.uniq
              return levels.first if levels.one?

              raise LoweringError, "sprites put in order as the game runs (`draw_in_order`) sit at different depths, which " \
                                   "#{build_name} cannot make yet."
            end

            # A run's sprites front-most first: the list's last entry first, each the number of the
            # sprite of the run to place.
            def emit_ordered_run(run, placings)
              (run.objects.length - 1).downto(0) do |k|
                past = fresh("past_the_ordered")
                value(Build.list_get(run.order, Build.int(k)))
                @asm.load(:a, :b)
                @asm.or_a(:c)
                @asm.or_a(:d)
                @asm.jump(:nz, past)
                @asm.load(:a, :e)
                run.objects.each_with_index do |name, at|
                  other = fresh("not_sprite")
                  @asm.cp_a(at)
                  @asm.jump(:nz, other)
                  @asm.call(placings.fetch(name))
                  @asm.jump(past)
                  @asm.label(other)
                end
                @asm.label(past)
              end
            end

            # How deep a sprite sits: the one level it is declared at, for a sprite that never changes
            # layer (one that does is placed by #emit_layer_changing_sprites).
            def sprite_level(obj)
              levels = Stacking.levels_of(@stacking.depths, obj).uniq
              return levels.first if levels.one?

              raise LoweringError, "the sprite #{obj.declared.inspect} changes layer as the game runs, and #{build_name} " \
                                   "places it only among the sprites of a frame."
            end

            # A SPRITE PLACED AS IT WAS ON THE PASS BEFORE IS LEFT AS IT IS (Runtime::KeptSprites says
            # how). A sprite with a block (#posed_sprite_block) is placed by rt_place_kept_sprite alone,
            # its code three loads and a call: left as it is, changed where it is in the table, or
            # placed afresh. One not drawn and unchanged since is passed over before the call
            # (Runtime::KeptSprites::NOT_DRAWN). Any other kept sprite asks rt_sprite_kept, which answers Z for one no
            # write has changed since it was placed and whose place in the table is where it was, and
            # is otherwise placed by its own code and noted by rt_sprite_placed.
            def emit_placing_unless_unchanged(obj)
              return sprite_placement(obj) unless keeps_unchanged_sprites? && kept_sprites.include?(obj.name)

              block = posed_sprite_block(obj)
              if block
                passed = fresh("sprite_not_drawn")
                @asm.load(:a, [sprite_kept_at(obj) + Runtime::KeptSprites::PLACED])
                @asm.cp_a(Runtime::KeptSprites::NOT_DRAWN_AS_PLACED)
                @asm.jump_relative(:z, passed)
                @asm.load(:hl, sprite_kept_at(obj))
                @asm.load(:de, block)
                @bank_pose_tables ? @asm.load_bank_of(:a, block) : @asm.xor_a(:a)
                @asm.call("rt_place_kept_sprite")
                return @asm.label(passed)
              end
              @asm.load(:hl, sprite_kept_at(obj))

              done = fresh("sprite_left")
              @asm.call("rt_sprite_kept")
              @asm.jump(:z, done)
              sprite_placement(obj)
              @asm.load(:hl, sprite_kept_at(obj))
              @asm.call("rt_sprite_placed")
              @asm.label(done)
            end

            # A sprite kept as it was is placed afresh, when a number of it changed, by rt_sprite_posed
            # (Runtime::KeptSprites) from a block in the cartridge saying where its numbers are, with
            # its rows after it, rather than by code of its own working each out in 32 bits: the
            # label of the block, or nil for a sprite a block cannot say (a list that holds other
            # colours as the game runs, a sprite switched off for good, a place or a list written in
            # the program, more than a byte of poses or lists). Its rows are what its tables hold
            # (#pose_tables), side by side, so the block is read in one bank: the banks, in a game
            # that keeps its pose tables there.
            def posed_sprite_block(obj)
              lists = Array(obj.recolors)
              on, scene = showing_parts(obj)
              return nil if on.nil? || lists.any?(Symbol) || obj.poses.length > 0xFF || lists.length > 0xFF
              return nil if (folded(on) && folded(on) != 1) ||
                            [obj.pose, obj.x, obj.y, *(obj.recolor unless lists.empty?)].any? { |number| folded(number) }

              pieces = single_pieces(obj)
              rows = pose_rows(obj, sprite_level(obj)).each_slice(obj.poses.length).flat_map do |list_rows|
                list_rows.each_with_index.flat_map do |row, pose|
                  # Runtime::KeptSprites::ROW_BYTES, in its order.
                  [*little_endian(row.picture, 2), *little_endian(Int32.wrap(row.attributes), 4),
                   @art.lends? ? row.palette : 0, *(pieces ? @art.piece_entry(pieces[pose]) : [0, 0])]
                end
              end
              place = ->(number) { little_endian(place_of(variable_named(value_node(number))), 2) }
              head = [pieces ? 1 : 0, *(pieces ? [pieces.first.dx, pieces.first.dy] : [0, 0]),
                      *(folded(on) ? [0, 0] : place.call(on)),
                      *(scene ? [*place.call(scene.first), scene.last] : [0, 0, 0]), *place.call(obj.pose),
                      obj.poses.length, *place.call(obj.x), *place.call(obj.y),
                      *(lists.empty? ? [0, 0] : place.call(obj.recolor)), lists.length]
              drawing_table("posed_sprite", 1, head + rows, banked: @bank_pose_tables)
            end

            # The one piece each of a sprite's poses is drawn from, when every one is a single piece in
            # the same place (rt_sprite_reposed changes such a sprite where it is in the table), or nil.
            def single_pieces(obj)
              return nil if obj.poses.any? { |name| picture_painting(name) }

              pieces = obj.poses.map { |name| @art.sprite_picture(name, picture_named(name)).pieces }
              return nil unless pieces.all? { |each| each.length == 1 }

              pieces.flatten.then { |all| all if all.map { |piece| [piece.dx, piece.dy] }.uniq.length == 1 }
            end

            # The sprites a frame places one by one whose every number is a variable or written in
            # the program, by name — a variable the game's code writes through Lowering#store or
            # #emit_sum, which mark the sprite changed, and not one this lowering moves on by itself
            # (#written_unmarked?). Not one drawn with a list that holds other colours as the game runs:
            # which row it is drawn from follows what the list holds, which is none of its numbers.
            def kept_sprites
              @kept_sprites ||= @program.walk.select { |node| node.kind == :present_objects }.flat_map(&:names).uniq.select do |name|
                obj = @objects.fetch(name)
                Array(obj.recolors).none?(Symbol) &&
                  sprite_numbers(obj).all? { |number| number.kind == :var_ref && !written_unmarked?(number.name) }
              end
            end

            # A variable this lowering writes where it is, with no mark: the frames counted at each
            # wait (Lowering#emit_wait_vblank), and the clock's readings (Lowering::Clock).
            def written_unmarked?(name) = [Frames::COUNT, Frames::STEP].include?(name) || name.to_s.start_with?("clock.")

            # The numbers a sprite is placed from that the game can change: whether it is on, its pose,
            # its place, and the list it is drawn with.
            def sprite_numbers(obj)
              [*showing_numbers(obj), obj.pose, obj.x, obj.y, (obj.recolor unless Array(obj.recolors).empty?)]
                .compact.map { |number| value_node(number) }.reject { |number| folded(number) }
            end

            # The numbers whether a sprite is on is worked out from: its own, and for one declared in
            # a scene the variable the game picks its scenes with (#showing_parts) — or the whole
            # sum, for a sprite whose on is neither.
            def showing_numbers(obj)
              on, scene = showing_parts(obj)
              return [obj.active] if on.nil?

              [on, (Build.var_ref(scene.first) if scene)]
            end

            # Whether a sprite is on, as its own number and the scene it shows in: a sprite declared
            # in a scene is on while its own number is and that scene is up (Builder#gated_by_scene),
            # [its number, [the variable the game picks its scenes with, the value that picks this
            # one]]; any other is [its number, nil]. Nil for a sum of another shape — a letter of text
            # shown while a condition holds is its scene and the condition — or a scene picked by a
            # number past a byte.
            def showing_parts(obj)
              active = value_node(obj.active)
              return [active, nil] unless active.kind == :binop && active.op == :*

              on, up = active.lhs, active.rhs
              return nil unless %i[var_ref int].include?(on.kind)
              return nil unless up.kind == :binop && up.op == :== && up.lhs.kind == :var_ref &&
                                up.rhs.kind == :int && up.rhs.value.between?(0, 0xFF)

              [on, [up.lhs.name, up.rhs.value]]
            end

            # The sprites kept as they were (#kept_sprites) placed from variable +name+.
            def sprites_placed_from(name)
              return [] unless @picture_sets&.empty?

              @sprites_by_number ||= kept_sprites.each_with_object(Hash.new { |all, key| all[key] = [] }) do |sprite, by|
                sprite_numbers(@objects.fetch(sprite)).each { |number| by[number.name] << sprite }
              end
              @sprites_by_number.fetch(name, [])
            end

            # Each sprite placed from variable +name+ marked changed, to be placed again
            # (Runtime::KeptSprites::PLACED): its place, when +name+ is where it is, its pose, when it
            # is its pose, and its other numbers, when +name+ is whether it is on, its scene or its list.
            def emit_sprites_changed(name)
              sprites_placed_from(name).uniq.each do |sprite|
                obj = @objects.fetch(sprite)
                names = ->(*numbers) { numbers.compact.map { |number| variable_named(value_node(number)) } }
                bits = []
                bits << Runtime::KeptSprites::PLACE_AS_PLACED if names.call(obj.x, obj.y).include?(name)
                bits << Runtime::KeptSprites::NUMBERS_AS_PLACED if names.call(*showing_numbers(obj), obj.recolor).include?(name)
                bits << Runtime::KeptSprites::POSE_AS_PLACED if names.call(obj.pose).include?(name)
                @asm.load(:hl, sprite_kept_at(obj) + Runtime::KeptSprites::PLACED)
                bits.each { |bit| @asm.res(bit, [:hl]) }
              end
            end

            # Where sprite +obj+ keeps what it was last placed with (Runtime::KeptSprites).
            def sprite_kept_at(obj)
              return Memory::FIRST if @measuring

              @sprites_kept_at ||= {}
              @sprites_kept_at[obj.name] ||= @memory.reserve("the sprite #{obj.name}'s last placing", Runtime::KeptSprites::BYTES)
            end

            # Reference#objects_on_screen: a sprite is drawn when it is switched on and its pose names
            # one of its pictures. It is drawn behind the background when the background's layer is
            # in front of its own; the background's see-through pixels still show it.
            #
            # +level+ is the depth it is placed at: its own, or for a sprite that changes layer as
            # the game runs, the one this placing is for (#emit_layer_changing_sprites).
            def sprite_placement(obj, level = sprite_level(obj))
              hidden = fresh("sprite_hidden")
              jump_unless(Build.binop(:==, value_node(obj.active), Build.int(1)), hidden)
              # A pose the program never changes is used as it is, so the build can see it is in range.
              said = folded(obj.pose)
              pose = said ? Build.int(said) : Build.var_ref(keep_local(:pose))
              unless said
                value(obj.pose)
                store(pose.name)
              end
              emit_refuse_pictures_not_up(obj, said, pose)
              unless fixed_sprite(obj, said, level)
                out_of_range = said ? nil : fresh("pose_out_of_range")
                if out_of_range
                  value(pose)
                  emit_jump_unless_below(obj.poses.length, out_of_range)
                end
                if said.nil? || said.between?(0, obj.poses.length - 1)
                  picture, attributes, lent = picture_and_attributes_drawn(obj, pose, level)
                  emit_sprite_call([*lent, picture, obj.x, obj.y, attributes])
                end
                @asm.label(out_of_range) if out_of_range
              end
              @asm.label(hidden)
            end

            # rt_sprite handed +args+. When each is a number written in the program, a variable or a
            # table entry read at one, none of them calls a routine that takes numbers of its own, so
            # each is written straight where rt_take_args would copy it to, lowest byte first, and
            # the copy is passed over (rt_sprite_args_set): two instructions a byte rather than a
            # push and a copy, which is most of placing a sprite of one piece.
            def emit_sprite_call(args)
              return runtime_call("rt_sprite", args) unless args.all? { |arg| read_without_args?(arg) }

              args.each_with_index do |arg, i|
                value(arg)
                at = Runtime::Calls.arg(@memory, i, args.length)
                BCDE_LOW_FIRST.each_with_index do |register, byte|
                  @asm.load(:a, register)
                  @asm.load_high(at + byte, :a)
                end
              end
              @asm.call("rt_sprite_args_set")
            end

            # Whether +operand+ is worked out without a runtime routine that takes numbers (#emit_sprite_call).
            def read_without_args?(operand)
              return true if folded(operand) || variable_named(operand)

              operand.is_a?(Entry) && read_without_args?(operand.index)
            end

            # To +label+ unless BCDE, taken as a whole number of 32 bits, is below +count+: a number
            # below nought is far past it. A count of a byte, as a sprite's poses are, is asked of the
            # bytes where they are; a bigger one of rt_cmpu32.
            def emit_jump_unless_below(count, label)
              if count <= 0xFF
                @asm.load(:a, :b)
                @asm.or_a(:c)
                @asm.or_a(:d)
                @asm.jump(:nz, label)
                @asm.load(:a, :e)
                @asm.cp_a(count)
                @asm.jump(:nc, label)
              else
                @asm.load(:hl, constant_label(count))
                @asm.call("rt_cmpu32")
                @asm.cp_a(1)
                @asm.jump(:nz, label)
              end
            end

            # A sprite's field as a value: a node, or a variable named by a Symbol.
            def value_node(operand) = operand.is_a?(Symbol) ? Build.var_ref(operand) : operand

            # A sprite whose picture, place and colours are all written in the program — a letter of
            # tiled text — is placed from a record of the four kept in the cartridge
            # (rt_sprite_fixed), with nothing worked out as the game runs. True when it was.
            def fixed_sprite(obj, pose, level)
              x = folded(obj.x)
              y = folded(obj.y)
              # In a game that lends its sprites' lists, which of the eight a sprite is drawn in is
              # known only as it runs, so even a letter of text takes the slower way, through
              # rt_sprite and the list it borrows as its first piece is placed, every pass.
              return false if @art.lends?
              return false unless pose && x && y && Array(obj.recolors).empty? && pose.between?(0, obj.poses.length - 1)

              name = obj.poses.fetch(pose)
              attributes = said_attributes(obj, name, palette_of(name, nil), level)
              record = [picture_number(name), x, y, attributes & 0xFFFF, attributes >> 16]
              runtime_call("rt_sprite_fixed", [Address.new(drawing_table("fixed_sprite", 2, record))])
              true
            end

            # Whether a sprite at depth +level+ is behind the scenery: a background sits in front of it.
            def behind_scenery?(level) = @stacking.scenery.any? { |bg| !bg.bar? && @stacking.depths.of_scenery(bg) > level }

            # Which picture a sprite showing pose number +pose+ is drawn from, and the attributes its
            # pieces are drawn with — which palette, and whether behind the background — now. Its
            # pictures are a row of poses in its own colours, then a row for each list it can be
            # drawn with (Reference#object_recolor), so the two tables are read at the same place. A
            # list that holds other colours as the game runs has a row for every set it can hold, the
            # ones it was declared with first (Reference#colors_held_by). In a game whose sprites' lists
            # borrow the console's eight (Art#lends?), the attributes name none of the eight, and a
            # third entry is the game's number for the list the row is drawn in, which rt_sprite
            # borrows one of the eight for as the sprite's first piece goes in; nil otherwise.
            def picture_and_attributes_drawn(obj, pose, level)
              lists = Array(obj.recolors)
              sets = sets_drawn_with(lists)
              banked = @bank_pose_tables
              pictures, palettes, lent_palettes = pose_tables(obj, level)
              at = lists.empty? ? pose : emit_row_and_pose_kept(obj, lists, sets, pose)
              lent = Entry.new(lent_palettes, 1, false, at, banked) if lent_palettes
              [Entry.new(pictures, 2, true, at, banked), Entry.new(palettes, 4, true, at, banked), lent]
            end

            # The sets of colours a sprite drawn with +lists+ is drawn in, row by row: its own, then
            # each list's (#picture_and_attributes_drawn).
            def sets_drawn_with(lists) = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]

            # The labels of a sprite's tables (#picture_and_attributes_drawn): its pictures and its
            # attributes, a row for each pose under each set of colours, and in a game whose sprites
            # borrow the eight lists, the list each row is drawn in (nil otherwise).
            def pose_tables(obj, level)
              rows = pose_rows(obj, level)
              # A row for every pose under every list is poses times lists, which a sprite of a few poses
              # walking a fade of many lists makes thousands of bytes of. A game whose part of the
              # cartridge always in view cannot hold them keeps them in its banks (GBC#build), read with
              # their bank put in view.
              banked = @bank_pose_tables
              pictures = drawing_table("pose_pictures", 2, rows.map(&:picture), banked: banked)
              palettes = drawing_table("pose_attributes", 4, rows.map(&:attributes), banked: banked)
              lent = drawing_table("pose_lent_palettes", 1, rows.map(&:palette), banked: banked) if @art.lends?
              [pictures, palettes, lent]
            end

            # A sprite's rows (PoseRow), a row for each pose under each set of colours it is drawn in,
            # the lists they are drawn in noted as worn in a game whose sprites borrow the eight.
            def pose_rows(obj, level)
              scene = lists_scene(obj)
              rows = sets_drawn_with(Array(obj.recolors)).flatten(1).flat_map do |colors|
                obj.poses.map do |name|
                  palette = palette_of(name, colors, scene: scene)
                  PoseRow.new(picture: picture_number(name), palette: palette,
                              attributes: said_attributes(obj, name, @art.lends? ? 0 : palette, level))
                end
              end
              @art.note_lists_worn(obj.name, rows.map(&:palette).uniq, scene: scene) if @art.lends?
              rows
            end

            # The scene whose own lists sprite +obj+ wears, in a game whose scenes number their own
            # (Art::TooManyLentLists): its scene, when that is one a scene's arrival hands over to,
            # since the arrival is what tells the lending whose numbers they are. Nil for the lists
            # every scene keeps.
            def lists_scene(obj)
              obj.scene if @art.lists_by_scene? && obj.scene && @scene && @scenes.key?(obj.scene)
            end

            # Where a sprite drawn with lists reads its tables: its row times its poses, plus its
            # pose. Worked out once and kept, since every table of the sprite is read at the same
            # place, and working out the row asks which list it is drawn with now and multiplies.
            def emit_row_and_pose_kept(obj, lists, sets, pose)
              kept = keep_local(:row_and_pose)
              value(Sum.new(:+, Sum.new(:*, row_drawn_with(obj, lists, sets), Build.int(obj.poses.length)), pose))
              store(kept)
              Build.var_ref(kept)
            end

            # One row of a sprite's tables: the picture a pose is drawn from in one list of colours,
            # the palette that list makes of it, and the attributes rt_sprite is handed for it.
            PoseRow = Data.define(:picture, :palette, :attributes)

            # Which row of its pictures a sprite is on: the first row of the list it is drawn with now,
            # and for a list that holds other colours, as many rows further as the set it holds.
            def row_drawn_with(obj, lists, sets)
              choice = RuntimeValue.new("rt_place_of_choice", [value_node(obj.recolor), Build.int(lists.length)])
              return choice if lists.none?(Symbol)

              first_rows = sets.each_with_object([0]) { |held, starts| starts << (starts.last + held.length) }
              # For each list, as rt_row_drawn_with reads it: its first row, where the number saying
              # which set it holds is kept (nought for a list that holds one set only), and how many
              # sets it holds besides the one it was declared with.
              entries = sets.each_index.flat_map do |at|
                name = at.zero? ? nil : lists[at - 1]
                held = name.is_a?(Symbol) ? place_of(@held_colors.fetch(name)) : 0
                others = name.is_a?(Symbol) ? sets_held_by(name).length - 1 : 0
                [first_rows[at] | (held << 16), others]
              end
              RuntimeValue.new("rt_row_drawn_with", [choice, Address.new(drawing_table("rows_drawn_with", 4, entries))])
            end

            # Reference#colors_held_by: every set of colours a named list can hold, the ones it was
            # declared with first, which is also what a number naming none of the others means.
            def sets_held_by(name)
              list = @color_lists.fetch(name) { raise LoweringError, "a sprite is drawn with the list of colors #{name.inspect}, which is not declared" }
              [list.colors, *list.recolors]
            end

            # Reference#exec_color_list_holds. Nothing is painted here: everything drawn with the list
            # reads what it holds as it is next drawn.
            def emit_color_list_holds(node)
              value(node.which)
              store(@held_colors.fetch(node.name))
            end

            def picture_number(name)
              run = picture_painting(name)
              return @art.painted_sprite_picture(name, run.width, run.height).number if run

              @art.sprite_picture(name, picture_named(name)).number
            end

            # A sprite's attributes as rt_sprite takes them: in the low byte, its palette and
            # whether it is behind the background, as the sprite table keeps them; above that, the
            # numbers a run says it by — whose it is, one up so nought is nobody's, and which picture
            # it is showing.
            def said_attributes(obj, picture, palette, level)
              behind = behind_scenery?(level) ? Console::GBCHardware::OBJ_BEHIND : 0
              whose = @drawn_sprites.name_number(obj.declared) + 1
              palette | behind | (whose << 8) | (@drawn_sprites.picture_number(picture) << 16)
            end

            # The palette picture +name+ is drawn in with the list +colors+ (nil for its own): the
            # colour each of its places shows, as the interpreter draws it. +scene+ is the scene whose
            # own lists the sprite wearing it is numbered among (#lists_scene).
            def palette_of(name, colors, scene: nil)
              run = picture_painting(name)
              return @art.painted_sprite_palette(name, painted_colors(run, colors), scene: scene) if run

              image = picture_named(name)
              @art.sprite_palette(name, image, sprite_pixels(image, colors), scene: scene)
            end

            # A sprite picture's pixels as the interpreter draws them (Reference#blit_image): the
            # number the picture stores, the colour +colors+ puts in its place when the sprite is
            # drawn with that list (Assets::Recolor), or Art::NOT_DRAWN where it is see-through.
            def sprite_pixels(image, colors)
              recolor = colors && Assets::Recolor.of(image, colors)
              Array.new(image.width * image.height) do |at|
                next Art::NOT_DRAWN unless image.drawn_at?(at)

                recolor ? recolor.color_for(at, image.raw_at(at)) : image.raw_at(at)
              end
            end

            def picture_named(name)
              Assets::Image.of(@pictures.fetch(name) { raise LoweringError, "a sprite shows the picture #{name.inspect}, which is not defined" })
            end

            # Reference#pixels_overlap?: each side's picture now, and where the second stands from the
            # first.
            def value_of_pixels_overlap(node)
              runtime_call("rt_pixels_overlap", [picture_collided(node.a_poses, node.a_pose),
                                                     picture_collided(node.b_poses, node.b_pose),
                                                     Build.binop(:-, node.b_x, node.a_x), Build.binop(:-, node.b_y, node.a_y)])
            end

            # Which picture a sprite collides as: the one of +poses+ its pose names, counted back from
            # the last for a pose below nought (Reference#collision_sprite).
            def picture_collided(poses, pose)
              poses.each { |name| refuse_too_big_to_collide!(name) }
              pictures = drawing_table("collision_pictures", 2, poses.map { |name| picture_number(name) })
              Entry.new(pictures, 2, true, RuntimeValue.new("rt_pose_place", [value_node(pose), Build.int(poses.length)]))
            end

            # A picture made of pieces can be bigger than the mask a test of its pixels walks (Art::
            # LARGEST_SPRITE); a sprite showing one is refused that test, and told to test by a box.
            def refuse_too_big_to_collide!(name)
              image = picture_named(name)
              return if image.width <= Art::LARGEST_SPRITE && image.height <= Art::LARGEST_SPRITE

              raise LoweringError, "a sprite showing the picture #{name.inspect} is tested pixel by pixel for touching " \
                                   "another, and it is #{image.width}×#{image.height}. A Game Boy Color tests the " \
                                   "pixels of a picture of #{Art::LARGEST_SPRITE}×#{Art::LARGEST_SPRITE} at most. " \
                                   "To fix this, give the sprite a hitbox:, which is tested as a box."
            end

            # --- fades and tints ---

            # Reference#exec_fade, as a fade that walks the colours (IR::Fading walks every fade on a
            # console that cannot blend): toward black or white by the thirty-seconds the amount
            # comes to. A fade placed in the stack, or held to part of the screen, needs the blend.
            def emit_fade(node)
              if node.under || node.reaches
                raise LoweringError, "this program fades #{node.under ? 'under a layer (`under:`)' : "part of the screen (`#{node.reaches}:`)"}, " \
                                     "and a Game Boy Color can only fade the whole screen. To fix this, leave it out."
              end

              toward = node.toward == :white ? Runtime::Picture::TOWARD_WHITE : Runtime::Picture::TOWARD_BLACK
              runtime_call("rt_tint", [Build.int(toward), Build.int(0), walk_steps(node)])
            end

            # Reference#exec_tint: toward the colour, in thirty-seconds.
            def emit_tint(node)
              runtime_call("rt_tint", [Build.int(Runtime::Picture::TOWARD_COLOR),
                                           Build.int(Graphics::Color.resolve(node.color)), walk_steps(node)])
            end

            # FadeSteps' steps for a fade that walks the colours, worked out as the game runs, held to
            # 0..32 here: rt_tint reads only the low byte and the sign of what it is handed, so a fade
            # far past 100 would otherwise come round to a few steps.
            def walk_steps(node)
              steps = FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: true)
              Build.clamped(steps, Build.int(0), Build.int(Runtime::Picture::STEPS))
            end

            # --- tables of the drawing's numbers ---

            # A table of numbers one drawing step reads, kept in the data, and its label: +bytes+ an
            # entry, each kept as its low bytes (an Entry reading it says whether with its sign).
            # A +banked+ one is kept in a bank of the cartridge of its own, for a runtime routine
            # that puts it in view as it reads it (a BankedAddress), rather than in the part always
            # in view, where a game's code and tables need the room.
            def drawing_table(what, bytes, entries, banked: false)
              label = "#{what} #{@drawing_tables.length + 1}"
              @drawing_tables << DrawingTable.new(label: label, bytes: bytes, entries: entries, banked: banked)
              label
            end
          end
        end
      end
    end
  end
end
