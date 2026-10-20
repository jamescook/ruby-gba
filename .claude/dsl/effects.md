# DSL reference: Effects a game writes

The whole story of these verbs. The one-line index is `.claude/rules/dsl-reference.md`.

- `uses MyPack` (or `uses A, B`) — **bring in effects of the game's own, for this game alone.** A pack is a plain Ruby module whose methods are written in the game's own verbs: its public methods become verbs from the `uses` line on, its private methods are helpers its verbs call, and checks it answers with (`def self.checks = [...]`, each with `detect(program)` handing back findings) report on this build and no other. Nothing is added to every other game the process builds, so two games built side by side can each have a verb of the same name, and a game built in a Ractor can call one (a module's methods are written in the module, which a Ractor can run, where a verb made from a block at run time is not). The packs ruby-gba ships (`iris_out`, `fade_out`, `shake_screen` …) are every game's already; `uses` is for the ones a game writes.
  - **What a pack is for is a look one game has**: an iris drawn the way one game draws it, a menu with one game's cursor, a copy of a commercial game's effect down to its quirks. It is written in public verbs only, so it plays the same on the console, the interpreter, C and JavaScript with nothing else to do. What it cannot say is a gap in the framework, and the answer is a new verb in the framework, not a way round it.
  - **The pieces a pack builds an effect from**, beside every ordinary verb: `light.shape { |row| … }` and `light.circle(row)` give the game's light a shape of the pack's own a row at a time (see `spotlight` in drawing.md); `each_pass(:name) { |job| … }` steps an effect once a pass of the game loop, started and stopped by the game, and `once_a_frame` once a frame of real time (see control-flow.md); a light is switched off by `light.dark.set! 0`, which shows nothing and costs the console nothing.
  - **A pack keeps its own state as the game does**: variables (`var`), tables, a job under a name only it uses. A verb that sets things up once can keep a note on the game (`@my_pack_ready`), since a pack's methods run as the game's own.
  - Friendly errors: something that is not a module, a verb a pack has that ruby-gba already has (a pack cannot change what a built-in verb means), and two packs of one game with a verb of the same name. A pack's names include those of the modules it includes, so a name taken that way is refused too — but two packs that include one helper module share its methods, and that is not two verbs of one name. Using the same pack twice does nothing the second time.
  - **Worked example**: `test/ruby_gba/builder/test_game_defined_iris.rb` — The Minish Cap's iris as a game's own pack: the game's midpoint circle with each row showing the circle of the row above (as that game hands its rows to the console), closing from 150 by 4 a pass from the pass it is called, opening at another point, every row of every picture the copied game's, and every backend agreeing.

```ruby
module CopiedIris
  def close_iris(at:)
    light = copied_iris_light
    light.move_to(*at)
    light.dark.set! 100
    light.radius.set! 150
    each_pass(:copied_iris_closing).start   # 146 on this pass, then 142 ... 2, then 0
  end

  private

  def copied_iris_light
    return spotlight if @copied_iris_ready

    @copied_iris_ready = true
    light = spotlight
    light.shape { |row| light.circle((row - 1).clamp(0, 159)) }   # each row the circle of the row above
    each_pass(:copied_iris_closing) do |job|
      light.radius.sub! 4
      (light.radius <= 0).then { light.radius.set! 0; job.stop }
    end
    light
  end
end

RubyGBA.game "MY GAME" do
  uses CopiedIris
  # ...
  close_iris at: [120, 80]
end
```
