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
    scene_sprites_shown: { scene: :playing },
    still_sprites: {},
    see_through_amounts: { layer: :rays },
    tile_run_tile: { run: :box, number: 3 },
    tile_run_pending: { run: :box },
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
    }
    said.each { |name, words| assert_equal words, MadeNames.words_for_made_name(name), name.inspect }
    assert_nil MadeNames.words_for_made_name(:jump), "a routine the author named is not one of these"
  end

  # The parts a game chooses — a record's name, a font's, a scene's — spelled to run into
  # the framework's own words and into each other's. However they are chosen, no two names
  # made from them are the same name.
  AWKWARD = %i[file jobs places table buffered buffered_tiny tiny playing playing_up up step
               save all key x x_step].freeze

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
