# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# What a saved measurement can say about one routine's part of a frame
# (lib/ruby_gba/diagnostics/routine_profile.rb). Its counts are added up over every scene, which
# is right for ranking and wrong as a part of any one frame, so it also keeps the busiest
# scene's own reading.
class TestRoutineProfile < Minitest::Test
  runs_on :reference

  RoutineProfile = RubyGBA::Diagnostics::RoutineProfile
  Line = RubyGBA::Diagnostics::Profiler::Line

  # As much of a scene's reading as the profile looks at.
  Reading = Struct.new(:frames, :samples, :lines)

  # A scene measured over thirty frames, running +each_frame+ instructions a frame, with each
  # routine's part of them in per cent.
  def reading(each_frame, shares)
    lines = shares.map { |name, share| Line.new(name: name, label: name.to_s, samples: 0, share: share, where: :rom) }
    Reading.new(30, 30 * each_frame, lines)
  end

  # A game whose loop runs two thousand instructions in every scene: next to nothing beside
  # the playing scene's hundred thousand, and most of what the five menus do.
  def one_heavy_scene_among_menus
    menus = %i[title files options credits over].to_h { |name| [name, reading(2_500, __frame: 80.0, name => 20.0)] }
    menus.merge(playing: reading(102_000, __frame: 2.0, _scene_playing: 98.0))
  end

  def profile_of(scenes)
    work = { __frame: 12_000, _scene_playing: 100_000 }
    RoutineProfile.new(work: work, busiest: RoutineProfile.busiest_in(scenes))
  end

  # The loop is a tenth of the counts added up, because it is counted once for every scene.
  # Of a frame of the scene that has the least room to lose, it is a fiftieth.
  def test_a_routines_share_is_of_the_busiest_scene_and_not_of_the_sum
    share = profile_of(one_heavy_scene_among_menus).busiest_share_of(:__frame)

    assert_equal :playing, share.scene
    assert_in_delta 2.0, share.percent
  end

  def test_a_routine_that_did_nothing_in_the_busiest_scene_has_no_share_of_it
    profile = RoutineProfile.new(work: { __frame: 12_000, title_art: 400 },
                                 busiest: RoutineProfile.busiest_in(one_heavy_scene_among_menus))

    assert_in_delta 0.0, profile.busiest_share_of(:title_art).percent
  end

  # A routine the measurement never saw is new since the measuring, which is not the same as
  # one that did nothing: nothing is known about it.
  def test_a_routine_the_measurement_never_saw_has_no_share_to_give
    assert_nil profile_of(one_heavy_scene_among_menus).busiest_share_of(:added_since)
  end

  def test_a_profile_made_from_counts_alone_has_no_share_to_give
    assert_nil RoutineProfile.new(work: { __frame: 500 }).busiest_share_of(:__frame)
    assert_nil RoutineProfile.busiest_in({ title: Reading.new(0, 0, []) }), "a scene that ran no frame is no reading"
  end

  def test_a_game_with_no_scenes_is_its_own_busiest
    share = profile_of({ nil => reading(9_000, __frame: 97.5) }).busiest_share_of(:__frame)

    assert_nil share.scene
    assert_in_delta 97.5, share.percent
  end

  def test_the_busiest_scene_is_kept_when_the_profile_is_saved
    Dir.mktmpdir do |dir|
      path = profile_of(one_heavy_scene_among_menus).write(File.join(dir, "game.profile.json"))
      share = RoutineProfile.read(path).busiest_share_of(:__frame)

      assert_equal :playing, share.scene
      assert_in_delta 2.0, share.percent
    end
  end

  # A profile saved before the busiest scene was kept still reads, and has no share to give.
  def test_a_profile_saved_without_a_busiest_scene_still_reads
    Dir.mktmpdir do |dir|
      path = RoutineProfile.new(work: { __frame: 500 }).write(File.join(dir, "old.profile.json"))

      assert_nil RoutineProfile.read(path).busiest_share_of(:__frame)
      assert_equal 500, RoutineProfile.read(path).work_of(:__frame)
    end
  end
end
