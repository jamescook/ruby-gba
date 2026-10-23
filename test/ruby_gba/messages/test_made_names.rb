# frozen_string_literal: true

require "test_helper"

# THE NAMES THE BUILD MAKES UP for routines and variables nobody wrote — a save record's
# routines, the save machinery's own, a font's digit routine, a scene's sprite routine — and
# what a report calls each one. Made and read back through one table, so these ask the table
# itself: no build is needed to find out whether two names can meet.
class TestMadeNames < Minitest::Test
  MadeNames = RubyGBA::Messages::MadeNames

  # One set of parts for every kind of name, as the build would hand them over.
  SAMPLES = {
    save_record: { record: :file, piece: :save },
    save_directory: { record: :file, kept: :hearts },
    save_table: { column: :key },
    save_places: { piece: :all },
    save_jobs: { piece: :step },
    digit_routine: { font: :tiny },
    buffered_digit_routine: { font: :tiny },
    scene_sprites: { scene: :playing },
    scene_rows_hidden_for: { state: :where },
    scene_rows_hide: { state: :where },
    scene_loop_work: { scene: :playing, number: 2 },
    still_sprites: {},
    see_through_amounts: { layer: :rays },
    pool_stacking: { pool: :guard },
    pool_field: { pool: :guard, field: :hp },
    pool_part: { pool: :guard, part: :active },
    list_fill_routine: {},
    list_copy_routine: {},
    setup_fill: { list: :trail },
    pose_rows: { number: 2 },
    told_turn: { background: :field, part: :size },
    set_swap: { background: :ground },
    shared_rooms: { number: 0, part: :take },
    view_along_map: { background: :ground },
    tile_run_tile: { run: :box, number: 3 },
    tile_run_pending: { number: 0 },
    painted_copies: {},
    canvas_part: { canvas: :box, part: :pixel },
    canvas_font: { font: :tiny, part: :rows },
    draw_order: { number: 1, part: :sort },
  }.freeze

  def test_every_kind_of_name_is_in_the_samples
    assert_equal MadeNames.kinds.sort, SAMPLES.keys.sort
  end

  def test_a_made_name_reads_back_as_the_kind_and_parts_it_was_made_from
    SAMPLES.each do |kind, parts|
      name = MadeNames.make(kind, **parts)
      assert_equal [kind, parts.transform_values(&:to_s)], MadeNames.read(name), name.inspect
    end
  end

  def test_a_routine_the_build_made_is_said_in_the_authors_own_terms
    said = {
      MadeNames.make(:save_record, record: :file, piece: :save) => "saving save_data :file",
      MadeNames.make(:save_record, record: :jobs, piece: :load) => "loading save_data :jobs",
      MadeNames.make(:save_places, piece: :all) => "finding where each save_data record lives in save memory",
      MadeNames.make(:save_jobs, piece: :tick) => "keeping the save_data saves in line",
      MadeNames.make(:digit_routine, font: :tiny) => "drawing a draw_number's digits (:tiny)",
      MadeNames.make(:buffered_digit_routine, font: :tiny) => "drawing a draw_number's digits (:tiny)",
      MadeNames.make(:scene_sprites, scene: :playing) => "moving the sprites of scene :playing",
      MadeNames.make(:still_sprites) => "writing the sprites nothing moves",
      MadeNames.make(:see_through_amounts, layer: :rays) => "telling the display how see-through layer :rays is",
      MadeNames.make(:pool_stacking, pool: :guard) => "putting the sprites of pool :guard oldest in front",
      MadeNames.make(:draw_order, number: 1, part: :sort) => "putting the sprites of draw_in_order #1 in order",
      MadeNames.make(:set_swap, background: :ground) => "bringing background :ground another set of tiles",
      MadeNames.make(:view_along_map, background: :ground) => "bringing the view of background :ground along its map",
      MadeNames.make(:shared_rooms, number: 0, part: :take) => "giving a sprite a room in sprite memory for the pose it shows",
      MadeNames.make(:shared_rooms, number: 0, part: :let_go) => "taking back the room of a sprite that is not shown",
      MadeNames.make(:pool_part, pool: :guard, part: :remove) => "removing an instance of pool :guard",
      MadeNames.make(:pool_part, pool: :guard_walk, part: :unlink) => "taking an instance of pool :guard_walk out of its order",
      MadeNames.make(:setup_fill, list: :trail) => "filling list :trail a push at a time, before the game loop",
      MadeNames.make(:setup_fill, list: MadeNames.make(:pool_part, pool: :guard, part: :free)) =>
        "filling pool :guard a push at a time, before the game loop",
    }
    said.each { |name, words| assert_equal words, MadeNames.words_for_made_name(name), name.inspect }
    assert_nil MadeNames.words_for_made_name(:jump), "a routine the author named is not one of these"
  end

  # The parts a game chooses — a record's name, a font's, a scene's — spelled to run into
  # the framework's own words and into each other's. However they are chosen, no two names
  # made from them are the same name.
  AWKWARD = %i[file jobs places table buffered buffered_tiny tiny playing playing_up up step
               save all key x x_step active field_x].freeze

  # A pool's field and the pool's own list of the same name, and the lists of two pools whose
  # names and fields spell the same words.
  def test_a_pools_field_is_never_the_pools_own_list_or_another_pools
    own = MadeNames.make(:pool_part, pool: :guard, part: :frame)
    field = MadeNames.make(:pool_field, pool: :guard, field: :frame)
    refute_equal own, field

    assert_equal [:pool_field, { pool: "guard", field: "walk__x" }],
                 MadeNames.read(MadeNames.make(:pool_field, pool: :guard, field: :walk__x))
    assert_equal [:pool_part, { pool: "guard_walk", part: "walk1_at" }],
                 MadeNames.read(MadeNames.make(:pool_part, pool: :guard_walk, part: :walk1_at))
  end

  # A report or an error names a list the build made up by what the author declared: a
  # record, a canvas, an order, a pool. The save machinery's own records read as what they are.
  def test_a_made_up_list_is_said_as_what_the_author_declared
    said = ->(kind, **parts) { MadeNames.collection_words(MadeNames.make(kind, **parts)) }

    assert_equal "pool :guard", said.call(:pool_field, pool: :guard, field: :x)
    assert_equal "save_data :file", said.call(:save_record, record: "file", piece: "stage")
    assert_equal "the save_var numbers",
                 said.call(:save_record, record: RubyGBA::IR::SaveLayout::SAVE_VAR_RECORD, piece: "stage")
    assert_equal "the save_data bookkeeping", said.call(:save_record, record: "__table", piece: "stage")
    assert_equal "canvas :board", said.call(:canvas_part, canvas: :board, part: :pixels)
    assert_equal "draw_in_order #2", said.call(:draw_order, number: 2, part: :keys)
    assert_equal "list :trail", MadeNames.collection_words(:trail)
  end

  # The framework's own records are known by their exact names, so another one it may add, named
  # with an underscore as they are, is never taken for the save_vars' record.
  def test_only_the_frameworks_own_records_read_as_its_own
    assert_equal "save_data :_extra",
                 MadeNames.collection_words(MadeNames.make(:save_record, record: "_extra", piece: "stage"))
  end

  def test_a_pool_name_cannot_end_its_own_names_early
    %i[guard guard_walk _guard g].each { |name| assert_match MadeNames::POOL_NAME, name.to_s }
    %i[guard_ guard__walk __guard _].each { |name| refute_match MadeNames::POOL_NAME, name.to_s }
  end

  def test_no_two_names_made_from_different_parts_are_the_same
    made = {}
    MadeNames.kinds.each do |kind|
      part_names = SAMPLES.fetch(kind).keys
      AWKWARD.repeated_permutation(part_names.size).each do |values|
        parts = part_names.zip(values).to_h
        name = MadeNames.make(kind, **parts)
        other = made[name]
        assert_nil other, "#{name.inspect} is made both from #{other.inspect} and from #{[kind, parts].inspect}"
        made[name] = [kind, parts]
      end
    end
  end
end
