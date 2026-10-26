# frozen_string_literal: true

require "test_helper"

# THE RULE THE QUICK MEMORY IS SHARED OUT BY, held with made-up routines and sizes rather than
# whole games. What the author insisted on is placed first, in the room of the scene that runs
# it; what the build picks for itself fills what is left, best first.
class TestQuickMemoryPlan < Minitest::Test
  Plan = GBA::QuickMemoryPlan

  private def claim(name, bytes, **rest) = Plan::Claim.new(name: name, bytes: bytes, **rest)

  def test_what_the_author_insisted_on_goes_in_before_what_the_build_would_pick
    plan = Plan.choose([claim(:__frame, 800), claim(:save_step, 600, insisted: "`save_data :file, fast: true`")],
                       room: 1000)

    assert plan.kept?(:save_step)
    refute plan.kept?(:__frame)
  end

  # Only what the author insisted on can stop a build, so the message names their own words.
  def test_an_insisted_routine_with_no_room_stops_the_build_naming_what_the_author_wrote
    error = assert_raises(GBA::QuickMemoryFull) do
      Plan.choose([claim(:__frame, 100), claim(:play_work, 1200, insisted: "`func :play_work, fast: true`")], room: 1000)
    end

    assert_match(/`func :play_work, fast: true`/, error.message)
    assert_match(/1200 bytes/, error.message)
    assert_match(/1000 are free/, error.message)
  end

  # A CALL BETWEEN TWO KEPT ROUTINES IS A PLAIN JUMP, so the bytes each was charged for it as a
  # call between the two memories come back once both are in. 600 + 420 is more than the room;
  # less the 20 the call between them was charged, it is exactly the room.
  def test_a_routine_fits_beside_the_routine_that_calls_it
    plan = Plan.choose([claim(:draw, 600, calls: [:sort], call_charge: 20), claim(:sort, 420)], room: 1000)

    assert plan.kept?(:draw)
    assert plan.kept?(:sort)
  end

  # A kept routine is down as what it was charged in the end, its call to a neighbour given back;
  # one left in the cartridge as what it would have taken.
  def test_each_routine_is_down_as_what_it_was_charged_in_the_end
    plan = Plan.choose([claim(:draw, 600, calls: [:sort], call_charge: 20), claim(:sort, 420), claim(:menu, 900)],
                       room: 1000)

    assert_equal({ draw: 580, sort: 420, menu: 900 }, plan.charged)
    assert_equal [Plan::Missed.new(name: :menu, bytes: 900, room: 0, scene: nil)], plan.missed
  end

  # ...and one turned away near the top of the list gets its chance again once a routine it calls
  # has gone in below it.
  def test_a_routine_turned_away_fits_once_the_routine_it_calls_is_in
    plan = Plan.choose([claim(:draw, 700, calls: %i[sort sort], call_charge: 20), claim(:sort, 300)], room: 960)

    assert plan.kept?(:sort)
    assert plan.kept?(:draw), "700 less two calls of 20 is 660, which fits beside sort's 300"
  end

  # A game whose scenes are picked by one dispatch in the game loop, which can swap each scene's
  # own routines in as it takes over.
  FILES_AND_PLAY = Plan::Dispatch.new(scenes: %i[_scene_files _scene_play], clauses: 2)

  # TWO WORDS THAT DO NOT FIT TOGETHER, ON TWO SCREENS THAT ARE NEVER UP TOGETHER: each gets the
  # room of the scene that runs it.
  def test_insisted_routines_of_two_scenes_each_get_their_scenes_room
    plan = Plan.choose([claim(:save_step, 700, scene: :_scene_files, insisted: "`save_data :file, fast: true`"),
                        claim(:play_work, 700, scene: :_scene_play, insisted: "`func :play_work, fast: true`")],
                       room: 1000, dispatch: FILES_AND_PLAY)

    assert_equal({ _scene_files: [:save_step], _scene_play: [:play_work] }, plan.sets)
  end

  # Only the routines one scene insisted on can fill that scene's room, so the message says which
  # scene and how far over.
  def test_insisted_routines_too_big_for_their_scene_name_the_scene
    error = assert_raises(GBA::QuickMemoryFull) do
      Plan.choose([claim(:save_step, 600, scene: :_scene_files, insisted: "`save_data :file, fast: true`"),
                   claim(:save_scan, 500, scene: :_scene_files, insisted: "`save_data :file, fast: true`"),
                   claim(:play_work, 100, scene: :_scene_play, insisted: "`func :play_work, fast: true`")],
                  room: 1000, dispatch: FILES_AND_PLAY)
    end

    assert_match(/`save_data :file, fast: true`/, error.message)
    assert_match(/files scene/, error.message)
  end

  # A GAME WHOSE ROUTINES DO NOT ALL FIT gives each scene the room the whole game does not need.
  def test_each_scene_keeps_its_own_busy_routine_when_one_set_cannot_hold_both
    plan = Plan.choose([claim(:title_work, 700, scene: :_scene_title), claim(:play_work, 700, scene: :_scene_play)],
                       room: 1000, dispatch: Plan::Dispatch.new(scenes: %i[_scene_title _scene_play], clauses: 2))

    assert_equal({ _scene_title: [:title_work], _scene_play: [:play_work] }, plan.sets)
  end

  # EACH SCENE'S ROOM GOES TO WHAT A FRAME OF THAT SCENE SPENDS THE MOST IN. Added up over both
  # scenes the routine they share reads dearest, so it is first in the order given; kept for the
  # whole game it leaves neither scene room for its own routine, where a frame of either spends more.
  def test_each_scenes_room_goes_to_what_a_frame_of_it_spends_most_in
    claims = [claim(:shared_work, 700, scene_work: { _scene_title: 1000, _scene_play: 1000 }),
              claim(:title_work, 700, scene: :_scene_title, scene_work: { _scene_title: 1500 }),
              claim(:play_work, 700, scene: :_scene_play, scene_work: { _scene_play: 1500 })]
    plan = Plan.choose(claims, room: 1200, dispatch: Plan::Dispatch.new(scenes: %i[_scene_title _scene_play], clauses: 2))

    assert_equal({ _scene_title: [:title_work], _scene_play: [:play_work] }, plan.sets)
    refute plan.kept?(:shared_work)
  end

  # ...though what every frame runs for one scene alone — the routine that brings play's map along
  # — can go to that scene's set: there it is still in the quick memory whenever it runs.
  def test_a_scenes_own_every_frame_routine_may_move_to_its_set
    plan = Plan.choose([claim(:__frame, 300, every_frame: true), claim(:play_view, 300, scene: :_scene_play, every_frame: true),
                        claim(:title_work, 500, scene: :_scene_title), claim(:play_work, 500, scene: :_scene_play)],
                       room: 1400, dispatch: Plan::Dispatch.new(scenes: %i[_scene_title _scene_play], clauses: 2))

    assert_equal({ _scene_title: [:title_work], _scene_play: %i[play_view play_work] }, plan.sets)
  end

  # ...BUT WHAT EVERY FRAME RUNS STILL GOES FIRST, in either order. Measured per scene the game
  # loop reads cheap, since each scene's frame spends most of its time somewhere else; it is still
  # the one routine every scene runs. Here what the two scenes insist on fits only in a set each,
  # and play's own busy routine, taken first, would leave the game loop no room.
  def test_what_every_frame_runs_goes_first_whichever_order_fills_the_scenes
    claims = [claim(:__frame, 300, every_frame: true, scene_work: { _scene_files: 10, _scene_play: 10 }),
              claim(:play_extra, 400, scene: :_scene_play, scene_work: { _scene_play: 1500 }),
              claim(:save_step, 650, scene: :_scene_files, insisted: "`save_data :file, fast: true`"),
              claim(:play_work, 650, scene: :_scene_play, insisted: "`func :play_work, fast: true`")]
    plan = Plan.choose(claims, room: 1200, dispatch: FILES_AND_PLAY)

    assert_includes plan.resident, :__frame
  end

  # ...AND A SAVE THE GAME DID NOT INSIST ON COMES AFTER IT. The file screen is measured with a
  # save running (Diagnostics::SaveStarts), and a save is written in a few passes and then stops,
  # so what a frame of that screen spends on it is its cost spread over every frame measured. Here
  # it is still more than the routine answering the display spends on that screen, and taken first
  # it fits, but that routine runs on every frame of every screen: where the two do not fit
  # together, the save is the one left out.
  def test_a_save_measured_on_one_screen_comes_after_what_every_frame_runs
    claims = [claim(:save_step, 600, scene_work: { _scene_files: 400 }),
              claim(:__interrupt, 600, every_frame: true, scene_work: { _scene_files: 300, _scene_play: 300 }),
              claim(:play_work, 500, scene: :_scene_play, scene_work: { _scene_play: 400 }),
              claim(:files_work, 500, scene: :_scene_files, scene_work: { _scene_files: 400 })]
    plan = Plan.choose(claims, room: 1200, dispatch: FILES_AND_PLAY)

    assert_includes plan.resident, :__interrupt
    refute_includes plan.resident, :save_step
  end

  # A GAME WHOSE ROUTINES ALL FIT SWAPS NOTHING.
  def test_a_game_whose_routines_all_fit_keeps_one_set
    plan = Plan.choose([claim(:title_work, 400, scene: :_scene_title), claim(:play_work, 400, scene: :_scene_play)],
                       room: 1000, dispatch: Plan::Dispatch.new(scenes: %i[_scene_title _scene_play], clauses: 2))

    assert_empty plan.sets
    assert_equal Set[:title_work, :play_work], plan.resident
  end

  # ...and one set is kept where the words a split costs would put what every frame runs in the
  # cartridge: the game loop fits beside nothing else in one set, and not beside the words.
  def test_a_split_that_would_leave_out_what_every_frame_runs_is_not_used
    plan = Plan.choose([claim(:__frame, 960, every_frame: true), claim(:title_work, 30, scene: :_scene_title),
                        claim(:play_work, 30, scene: :_scene_play)],
                       room: 1000, dispatch: Plan::Dispatch.new(scenes: %i[_scene_title _scene_play], clauses: 2))

    assert_empty plan.sets
    assert plan.kept?(:__frame)
  end

  # THE PROMISE THE RULE IS FOR: however play grows, what the file screen insisted on keeps its
  # room — and whatever the build would have picked ahead of it, measured or not, the answer for
  # what the author insisted on is the same.
  def test_play_growing_never_takes_the_file_screens_insisted_room
    save = claim(:save_step, 900, scene: :_scene_files, insisted: "`save_data :file, fast: true`")
    (0..4000).step(250) do |bytes|
      play = claim(:play_work, bytes, scene: :_scene_play)
      [[claim(:__frame, 700, every_frame: true), play, save], [play, save, claim(:__frame, 700, every_frame: true)]].each do |claims|
        assert Plan.choose(claims, room: 2000, dispatch: FILES_AND_PLAY).kept?(:save_step), "dropped with play at #{bytes}"
      end
    end
  end

  # WHETHER A BUILD STOPS IS THE AUTHOR'S ALONE: the same insisted routines stop it, or do not,
  # whatever the build would pick beside them and whatever a measurement said of those.
  def test_whether_the_build_stops_does_not_depend_on_what_was_measured
    insisted = [claim(:save_step, 600, scene: :_scene_files, insisted: "`save_data :file, fast: true`"),
                claim(:save_scan, 500, scene: :_scene_files, insisted: "`save_data :file, fast: true`")]
    picks = [[], [claim(:__frame, 900, every_frame: true)],
             [claim(:__frame, 900, every_frame: true, scene_work: { _scene_files: 5000, _scene_play: 5000 }),
              claim(:play_work, 700, scene: :_scene_play, scene_work: { _scene_play: 9000 })]]
    [1000, 1200].each do |room|
      outcomes = picks.map do |optional|
        Plan.choose(insisted + optional, room: room, dispatch: FILES_AND_PLAY) && :built
      rescue GBA::QuickMemoryFull => e
        e.message
      end

      assert_equal 1, outcomes.uniq.size, "room #{room}: #{outcomes.inspect}"
    end
  end

  def test_an_insisted_routine_nothing_calls_is_refused_as_never_running
    error = assert_raises(GBA::LoweringError) do
      Plan.choose([claim(:spare, nil, insisted: "`func :spare, fast: true`")], room: 1000)
    end

    assert_match(/`func :spare, fast: true`/, error.message)
    assert_match(/nothing calls it/, error.message)
  end
end
