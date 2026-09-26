# frozen_string_literal: true

require "test_helper"
require "open3"

# THE SUITE RUNS EVERY TEST IN A RACTOR OF ITS OWN, and naming one test must not quietly stop
# that. Rake's test task reads TESTOPTS INSTEAD of the options the task was given, not as well
# as them, so a Rakefile that only put `--ractor` in the task's own options lost it the moment
# anybody picked a test by name: that one test then ran on plain threads, where something the
# suite refuses passes, and nothing but a missing word in "Run options" said so.
#
# Each case runs the real `rake test` over one quick test of another file, so it cannot run
# itself again. (One real test and not none: the Ractor runner stops a run with nothing in it.)
class TestRakefile < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  ROOT = File.expand_path("../..", __dir__)

  private def run_options(testopts)
    out, = Open3.capture2e({ "TESTOPTS" => testopts }, "bundle", "exec", "rake", "test",
                           "TEST=test/ruby_gba/graphics/test_color.rb", chdir: ROOT)
    out[/^Run options: .*$/] or flunk("rake test printed no run options:\n#{out}")
  end

  def test_naming_a_test_keeps_every_test_in_its_own_ractor
    assert_match(/(^| )--ractor( |$)/, run_options("--name=/test_rgb_packs_channels/"))
  end

  # A pattern that happens to contain the word is not the flag. (Quoted, because rake hands
  # the options to a shell.)
  def test_a_name_holding_the_word_ractor_still_gets_the_flag
    assert_match(/(^| )--ractor( |$)/, run_options("--name='/test_rgb_packs_channels|ractor/'"))
  end

  # Somebody who asks for plain threads gets them.
  def test_asking_for_no_ractors_is_left_alone
    refute_match(/(^| )--ractor( |$)/, run_options("--no-ractor --name=/test_rgb_packs_channels/"))
  end
end
