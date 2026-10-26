# frozen_string_literal: true

# EVERY VERB A GAME CAN WRITE, worked out from what is mixed into Builder right now, for the tests
# that hold something to every verb: the DSL reference (test_dsl_reference.rb) and each
# console's answer for every verb (test_answers.rb).
module DslVerbs
  # The DSL verbs are the public methods the concern modules mix into Builder…
  CONCERNS = RubyGBA::Builder.included_modules.select { |m| m.name&.start_with?("RubyGBA::Builder::") }.freeze

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
  # record_light_shape, light_circle and show_light_now are the hooks behind `shape`, `circle`
  # and `show_now` on the light, documented on `spotlight`. game_pack_checks is what a build asks of `uses`, documented there.
  # record_clock_set is the hook behind `set_to` on the clock, documented on `clock`.
  SKIP = %i[variables debug_halted? make_object_rotatable make_object_scalable
            remember_sprite_recolors remember_background_draws_with
            record_row_bend make_background_affine screen_pages keep_showing_pictures
            tile_collision_routine play_from_list play_sound_effect
            declare_instance_routine record_walk_instance_writes pool_walk_scratch_var
            colors_to_draw_with make_object_recolorable make_pool_recolorable
            make_object_layer_choosable refuse_unknown_layers! write_picked_choice
            lists_drawn_from list_drawn_from declared_colors name_of_colors pool_refill_nodes
            request_tile_copy canvas_font canvas_font_tables image_size image_pixels write_picked_pose
            record_light_shape light_circle show_light_now game_pack_checks record_clock_set].freeze

  # …plus the verbs the loaded effect packs contribute. A pack's verb is an ordinary
  # DSL verb at the call site, so it has to be looked up in the same place.
  def dsl_verbs
    (CONCERNS.flat_map { |m| m.public_instance_methods(false) } +
     BUILDER_VERBS + RubyGBA::Effects.verbs.keys - SKIP).uniq.sort
  end
end
