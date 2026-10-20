# frozen_string_literal: true

require "test_helper"

# Keeps the DSL reference honest. It comes in two halves: .claude/rules/dsl-reference.md,
# a short index that every session loads (a line per verb, pointing at its group), and
# .claude/dsl/<group>.md, the whole story of each group, read only when it is wanted.
# This walks the DSL verbs actually mixed into Builder right now and fails if any is
# missing from either half — the failure names the missing verb and says how to fix it.
# A crude but effective coverage check (it looks for the verb name as a word; it doesn't
# police the signature).
class TestDslReference < Minitest::Test
  SHEET = RubyGBA.root.join(".claude/rules/dsl-reference.md").to_s

  # The index is loaded into every session, so it is held to a line a verb. The cap is a
  # little over twice its size when it was split off, and well under the 150,000 characters
  # at which a session warns that a rules file is slowing it down. A paragraph belongs in a
  # group file.
  MOST_INDEX_CHARACTERS = 40_000

  # The DSL verbs are the public methods the concern modules mix into Builder…
  CONCERNS = RubyGBA::Builder.included_modules.select { |m| m.name&.start_with?("RubyGBA::Builder::") }

  # …plus these verbs defined on Builder itself (the rest of its public methods are
  # framework: program, finalize_program, record_*, the Condition bookkeeping).
  BUILDER_VERBS = %i[list entry].freeze

  # Public concern methods that are introspection/debug, not verbs to look up — the
  # reference needn't spell each out. Move a verb here only if it's genuinely not
  # part of the authoring surface.
  # make_object_rotatable / make_object_scalable are not authoring verbs — they're
  # internal hooks a HardwareSprite handle calls to wire up its rotation and its size
  # (see #face_angle / #turn / #scale), which the reference documents on the sprite
  # verb, not on their own lines. record_row_bend is the same: the hook behind
  # Background#scroll_each_row, documented on the background verb.
  # screen_pages and keep_showing_pictures are introspection behind `keep_showing`:
  # how many pictures the chosen screen keeps, and the pictures declared so far. The
  # reference documents the verb; a game reads neither of these to write one.
  # tile_collision_routine is the same kind of hook: a HardwareSprite told `blocked_by`
  # asks for the shared routine that consults the background's grid of solid cells. The
  # reference documents `blocked_by`; nobody writes this.
  # play_from_list is the hook behind SongList#play, which the reference documents on the
  # `songs` verb — a game writes `music.play track`, never this. play_sound_effect is the same
  # hook behind SoundEffectList#play, documented on `sound_effects`.
  # The three pool-walk ones are the seam between a Pool and the build, behind `pool.func`:
  # declaring one of its routines, and remembering where a walk is so a routine can be told
  # which instance it ran for. The reference documents `pool.func`; nobody writes these.
  # The three recolouring ones are the hooks behind `draw_with` on a sprite and on a pool
  # instance: checking the lists named against the sprite's own, and giving a sprite or a
  # pool somewhere to keep its choice. The reference documents `colors` and `draw_with`.
  # The four list lookups are what a background drawn from several lists asks while it works
  # out which list is which, behind `draw_with` on a background.
  # pool_refill_nodes is the hook behind a save_data record's `reset` of a kept pool, which the
  # reference documents on `save_data`; nobody writes it. request_tile_copy is the hook
  # behind `changed` on tiles painted from a list, which the reference documents on `tiles`.
  # canvas_font, canvas_font_tables, image_size and image_pixels are what a `canvas` asks while
  # it builds its words, documented on `canvas`; nobody writes them. write_picked_pose is the
  # hook behind `face ..., showing:` on a sprite and a pool instance, documented on `sprite`.
  # make_object_layer_choosable and refuse_unknown_layers! are the hooks behind `put_in_layer` on a
  # sprite, documented under Layers.
  # remember_sprite_recolors and remember_background_draws_with are the hooks behind `recolor`:
  # a sprite, a pool and a background say which lists they draw with, so a list that changes
  # can find them. The reference documents `recolor`; nobody writes these.
  # record_light_shape and light_circle are the hooks behind `shape` and `circle` on the light,
  # documented on `spotlight`. game_pack_checks is what a build asks of `uses`, documented there.
  SKIP = %i[variables var_address debug_halted? make_object_rotatable make_object_scalable
            remember_sprite_recolors remember_background_draws_with
            record_row_bend make_background_affine screen_pages keep_showing_pictures
            tile_collision_routine play_from_list play_sound_effect
            declare_instance_routine record_walk_instance_writes pool_walk_scratch_var
            colors_to_draw_with make_object_recolorable make_pool_recolorable
            make_object_layer_choosable refuse_unknown_layers! write_picked_choice
            lists_drawn_from list_drawn_from declared_colors name_of_colors pool_refill_nodes
            request_tile_copy canvas_font canvas_font_tables image_size image_pixels write_picked_pose
            record_light_shape light_circle game_pack_checks].freeze

  # …plus the verbs the loaded effect packs contribute. A pack's verb is an ordinary
  # DSL verb at the call site, so it has to be looked up in the same place.
  private def dsl_verbs
    (CONCERNS.flat_map { |m| m.public_instance_methods(false) } +
     BUILDER_VERBS + RubyGBA::Effects.verbs.keys - SKIP).uniq.sort
  end

  # Match the verb name as a whole word (so `set` isn't satisfied by `set_cell`).
  private def mentions?(text, verb) = text.match?(/(?<!\w)#{Regexp.escape(verb.to_s)}(?!\w)/)

  private def verbs_missing_from(text)
    dsl_verbs.reject { |verb| mentions?(text, verb) }
  end

  # Each section of the index with the group file its heading points at (nil where it
  # points at none), as [heading, text, path relative to the repository].
  private def index_sections
    File.read(SHEET).split(/^## /).drop(1).map do |section|
      heading = section.lines.first.strip
      [heading, section, heading[%r{\.claude/dsl/[\w-]+\.md}]]
    end
  end

  def test_every_dsl_verb_is_in_the_index
    # Guard against a broken enumeration silently passing this test (empty concerns
    # would leave only list/entry, which are trivially present).
    assert_operator dsl_verbs.length, :>, 40, "DSL verb enumeration looks broken (#{dsl_verbs.length} verbs)"

    missing = verbs_missing_from(File.read(SHEET))
    assert_empty missing, <<~MSG
      These DSL verbs are missing from .claude/rules/dsl-reference.md:
        #{missing.join(', ')}
      Add a line for each (a short signature, what it does in a sentence, and its group
      file), and the whole story to that group file under .claude/dsl/ — or, if it isn't
      really an authoring verb, add it to SKIP in this test with a note why.
    MSG
  end

  def test_every_section_of_the_index_points_at_a_group_file_that_is_there
    unpointed = index_sections.reject { |_, _, path| path }.map(&:first)
    assert_empty unpointed, "These sections of the index name no group file under .claude/dsl/: #{unpointed.join('; ')}"

    absent = index_sections.filter_map { |_, _, path| path unless File.exist?(RubyGBA.root.join(path)) }
    assert_empty absent, "The index points at group files that are not there: #{absent.join(', ')}"
  end

  # A verb's index line is in the section that points at its group file, so the verb has to
  # be told there and not merely somewhere.
  def test_every_dsl_verb_is_told_in_full_in_the_group_file_its_section_points_at
    missing = index_sections.flat_map do |_, text, path|
      next [] unless path && File.exist?(RubyGBA.root.join(path))

      group = File.read(RubyGBA.root.join(path))
      dsl_verbs.select { |verb| mentions?(text, verb) && !mentions?(group, verb) }.map { |verb| "#{verb} (#{path})" }
    end

    assert_empty missing, <<~MSG
      These DSL verbs are on an index line but not in the group file that section points at:
        #{missing.join(', ')}
      Tell each one in full in that group file, or move its line to the section it belongs in.
    MSG
  end

  def test_the_index_stays_short_enough_to_load_every_session
    size = File.read(SHEET).length
    assert_operator size, :<=, MOST_INDEX_CHARACTERS, <<~MSG
      .claude/rules/dsl-reference.md is #{size} characters, over #{MOST_INDEX_CHARACTERS}. Every
      session loads it, so keep each verb to a line there and put the rest in its group file.
    MSG
  end
end
