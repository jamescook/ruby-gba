# frozen_string_literal: true

require "test_helper"

# Keeps .claude/rules/dsl-reference.md honest: it walks the DSL verbs actually mixed
# into Builder right now and fails if any isn't mentioned in the cheat-sheet. So a
# new verb can't quietly drift out of the reference — the failure names the missing
# verb and says how to fix it. A crude but effective coverage check (it looks for
# the verb name as a word; it doesn't police the signature).
class TestDslReference < Minitest::Test
  SHEET = File.expand_path("../.claude/rules/dsl-reference.md", __dir__)

  # The DSL verbs are the public methods the concern modules mix into Builder…
  CONCERNS = RubyGBA::Builder.included_modules.select { |m| m.name&.start_with?("RubyGBA::Builder::") }

  # …plus these verbs defined on Builder itself (the rest of its public methods are
  # framework: program, emit_pending_functions, record_*, the Condition bookkeeping).
  BUILDER_VERBS = %i[list entry].freeze

  # Public concern methods that are introspection/debug, not verbs to look up — the
  # cheat-sheet needn't spell each out. Move a verb here only if it's genuinely not
  # part of the authoring surface.
  # make_object_rotatable / make_object_scalable are not authoring verbs — they're
  # internal hooks a HardwareSprite handle calls to wire up its rotation and its size
  # (see #face_angle / #turn / #scale), which the cheat-sheet documents on the sprite
  # verb, not on their own lines. record_row_bend is the same: the hook behind
  # Background#scroll_each_row, documented on the background verb.
  # screen_pages and keep_showing_pictures are introspection behind `keep_showing`:
  # how many pictures the chosen screen keeps, and the pictures declared so far. The
  # cheat-sheet documents the verb; a game reads neither of these to write one.
  # tile_collision_routine is the same kind of hook: a HardwareSprite told `blocked_by`
  # asks for the shared routine that consults the background's grid of solid cells. The
  # cheat-sheet documents `blocked_by`; nobody writes this.
  # play_from_list is the hook behind SongList#play, which the cheat-sheet documents on the
  # `songs` verb — a game writes `music.play track`, never this.
  # The three pool-walk ones are the seam between a Pool and the build, behind `pool.func`:
  # declaring one of its routines, and remembering where a walk is so a routine can be told
  # which instance it ran for. The cheat-sheet documents `pool.func`; nobody writes these.
  SKIP = %i[variables var_address debug_halted? make_object_rotatable make_object_scalable
            record_row_bend make_background_affine screen_pages keep_showing_pictures
            tile_collision_routine play_from_list
            declare_instance_routine note_pool_walk pool_walk_scratch_var].freeze

  # …plus the verbs the loaded effect packs contribute. A pack's verb is an ordinary
  # DSL verb at the call site, so it has to be looked up in the same place.
  def dsl_verbs
    (CONCERNS.flat_map { |m| m.public_instance_methods(false) } +
     BUILDER_VERBS + RubyGBA::Effects.verbs.keys - SKIP).uniq.sort
  end

  def test_every_dsl_verb_is_in_the_cheat_sheet
    # The sheet lives under .claude/, which is gitignored (a local authoring aid, like
    # rules/testing.md), so a bare clone may not have it — skip rather than fail there.
    # On a dev machine that has it, the coverage check below is enforced.
    skip "no #{SHEET} (it's a local, gitignored aid)" unless File.exist?(SHEET)

    # Guard against a broken enumeration silently passing this test (empty concerns
    # would leave only list/entry, which are trivially present).
    assert_operator dsl_verbs.length, :>, 40, "DSL verb enumeration looks broken (#{dsl_verbs.length} verbs)"

    text = File.read(SHEET)
    # Match the verb name as a whole word (so `set` isn't satisfied by `set_cell`).
    missing = dsl_verbs.reject { |v| text.match?(/(?<!\w)#{Regexp.escape(v.to_s)}(?!\w)/) }

    assert_empty missing, <<~MSG
      These DSL verbs are missing from .claude/rules/dsl-reference.md:
        #{missing.join(', ')}
      Add each one (a one-line signature + what it does) so the cheat-sheet stays
      current — or, if it isn't really an authoring verb, add it to SKIP in this test
      with a note why.
    MSG
  end
end
