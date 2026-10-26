# VBlank

A Ruby DSL for building Game Boy Advance cartridges, aimed at someone who knows Ruby
and is not assumed to know the hardware. So the language here has two halves — the
words a game author writes, and the words the framework uses about itself — and where
the hardware has a name for a thing, the half an author reads prefers the plain one.

## What an author writes

**Verb**:
One call in a `VBlank.build` / `VBlank.game` block — `pixel`, `sprite`, `scene`. The
flat surface an author learns.
_Avoid_: command, API method, primitive

**Handle**:
The object a verb hands back so later code can name what it made — a `Value`, a
`Sprite`, a `Pool`. A handle is how an author refers to a thing, never how the thing
works.
_Avoid_: reference, wrapper, proxy

**Screen**:
What a game draws to, picked by name (`:bitmap`, `:tiled`, `:rotozoom`). It decides
which kind of sprite `sprite` makes and which drawing verbs are legal.
_Avoid_: display mode, Mode 3/4/0, DISPCNT, video mode

**Scene**:
A named game state that runs once a frame while it is the active one — the title, the
playing field, game over. A scene owns what it declares: its sprites and text
are on screen exactly while it is active. A scene is **when**.
_Avoid_: state machine state, screen (that word is taken), level

**Layer**:
A named place in the drawing stack that a background, a sprite or tiled text can belong
to. A layer is **where in the stack**, and it holds things rather than being a surface
anything is painted onto.
_Avoid_: priority, BG index, z-order

**Stack**:
The layers a game declares, back to front, in one `layers` call. The whole-screen answer
to what sits in front of what.
_Avoid_: layer order, z-stack

**Frame**:
One picture the console shows, 1/60 of a second. Distinct from a **pass** of the game
loop: while the work fits, one pass is one frame; when it does not, a pass spans two or
three, and anything counting passes and calling them frames is counting the wrong thing.
_Avoid_: tick, cycle, refresh

**Pass**:
One trip through the `game_loop` body. See **Frame**.
_Avoid_: iteration, frame

**Sprite**:
A picture the framework redraws for the author every frame, at a position the game moves.
On `screen :bitmap` it is drawn in software and leaves no trail; on `screen :tiled` the
console composites it. One verb, and an author is not asked which they got.
_Avoid_: OAM entry, object, actor, blitted image

**Background**:
A grid of tiles stamped from a map, drawn by the console on a tiled screen and scrolled
as one piece.
_Avoid_: tilemap layer, BG, tile layer

**Pool**:
Many of one component that has named fields and behaves — bullets, enemies, particles —
sized once at its worst moment.
_Avoid_: object pool, entity array, parallel lists

**Fraction**:
A number that carries halves and quarters, made by writing a Float (`var :px, 3.5`). Every
handle and every operation on it keeps the fraction; the author never says how fine it is.
_Avoid_: fixed point, Q16.16, scaled integer, fraction_bits

**Estimate hint**:
`estimate: { usually: N }` on a list, pool, loop, branch or stretched column — what a
normal frame does, as an author once said it for a cost estimate that is gone. A game that
still writes one is warned and plays the same; nothing reads it.
_Avoid_: annotation, pragma

**Effect pack**:
A bundle of verbs (and the guardrails for their footguns) built only from public verbs,
so no backend has to learn anything for it to work. Screen shake, fades, menus. A new
capability is a verb of the framework's own; a new convenience is a pack.
_Avoid_: plugin, extension, mixin

## What the framework is

**Game**:
A title and a DSL block (`VBlank.game`), with cartridge codes only if the author wants to
choose them. Building it is a separate step, so a game file only declares.
_Avoid_: project, app, sketch

**Program**:
The whole op-tree a DSL block builds, rooted at one node. This is the thing backends
consume and guardrails walk. It names the console it was built for, and every build names
one.
_Avoid_: AST, bytecode, source tree

**Unbound program**:
A program that names no console: one a test builds by hand, or with a Builder told no
console. Each test run plays it as that run's console. Nothing a game or a build makes is one.
_Avoid_: default console, the Advance's program

**IR**:
The node model a program is made of — plain Ruby data describing *what the program
does*, deliberately knowing nothing about any target machine.
_Avoid_: bytecode, opcode stream, instruction list

**Kind**:
What one node is (`pixel`, `set`, `loop`). A new kind has to be taught to every backend.
_Avoid_: opcode, type, node type

**Backend**:
A consumer of a program, named for the platform it targets. `GBA` lowers to a cartridge;
`Native` writes the game as C, built into a desktop program; `JS` writes it as JavaScript, for a
web page; `Reference` runs the program in Ruby.
_Avoid_: compiler, emitter, target (the CPU is not the target — the platform is)

**Console kit**:
The parts of the library that serve one console, named in one place (`Console.for(:gbc)`): what a
game can tell about it, what each verb does on it, the build that makes its cartridge, the kind of
cartridge, the reader that plays one back. A part that needs to know which console it is serving
asks the kit and never compares the console's name.
_Avoid_: platform (that is what a lowering targets), adapter, driver

**Lowering**:
Turning a program into code for one platform. Everything machine-specific lives here and
never in the IR. There are three: the GBA lowering, the native lowering and the JavaScript
lowering.
_Avoid_: codegen, compiling, emitting

**Reference interpreter**:
The `Reference` backend, run headless as the answer key: it has a fake screen and
variables a test reads. Named for its role, not for the language.
_Avoid_: simulator, emulator, mock

**ROM**:
The finished cartridge, header and checksum written. Called a **cartridge** in anything a
person reads; `ROM` is the artifact and the class.
_Avoid_: binary, output file

**Build record**:
What the build worked out about a cartridge and nobody can recover from the bytes
afterwards — which routines were kept in quick memory, where each variable landed, what
each line of the game became. The **build report** is read from it.
_Avoid_: metadata, build info, symbol table

## What the framework says to the person

**Friendly error**:
A message written for a learner: what happened, then what to do about it, in plain
language and never a hardware lecture. The house style for everything an author reads.
_Avoid_: nice error, exception message

**Guardrail**:
A check that walks a program before it is lowered and turns a known footgun into a
friendly error or warning. This is what the whole-program-as-data design is for.
_Avoid_: lint rule, assertion

**Finding**:
One thing a guardrail found: a severity (an error, or a warning), a message, and what it
blames. A finding must
name something to go and read — it cannot report a black screen without a line.
_Avoid_: diagnostic, issue

**Verification**:
The framework's three separate checks, which are not interchangeable: the **IR verifier**
checks a tree's internal consistency, **guardrails** check the program for footguns, and
**ROM validation** checks a finished cartridge's header and structure. None of them runs
the cartridge; reading a running one back is the emulator's (see **ruby-gba-emulator**).
_Avoid_: validation, verifier (on their own — say which)

**Plain words**:
The one English name each shared thing has — the quick memory, a routine nobody wrote —
used by the progress line, the guardrails and the reports alike, so one thing never gets
three names.
_Avoid_: strings, i18n, labels

**Messages**:
Everything a build says while it is building, and how it says it: the plain words above,
the progress line, where the printing goes, and which line of the author's own file to
blame. It runs when there is no cartridge yet, which is what separates it from
**diagnostics** — that one reads a finished or running cartridge back.
_Avoid_: output, logging, reporting

## What a game costs

What a frame costs is measured by running the game, never worked out from the program.

**Profile**:
The report a finished cartridge gives about itself (`vblank profile`, `rom.profile`): the
build report, then what the game cost when it ran.
_Avoid_: explain, stats, analysis

**Build report**:
The half of a profile the build already knows exactly, read from the **build record**: how
big each routine came out, what was kept in quick memory and what missed, which letters of a
font the game draws. Facts, never a prediction.
_Avoid_: prediction, cost model

**Measurement**:
The half of a profile read off the cartridge running in the emulator: which routines the
frames went to, how much of each frame was left over, the frame rate, and whether the
picture tore or flickered and any sound was dropped.
_Avoid_: benchmark, prediction, timing

**Measured build**:
Building a game twice: once with the quick memory chosen from the shape of the program,
then — after that cartridge is run and its scenes measured — again, choosing from what
the measuring found. What a game gets by default; with no emulator, only the first build.
_Avoid_: two-pass build, profile-guided build

**Quick memory**:
The console's 32K of memory that runs at full speed, as opposed to code fetched from the
cartridge. The build chooses what to keep there — its **placement** — and an author can
insist or refuse.
_Avoid_: IWRAM, fast RAM, internal work RAM, cache

## How it is checked

**ruby-gba-emulator**:
The headless emulator that runs a real cartridge and reads back its real pixels and sound.
A gem of its own, so that building a cartridge never needs a C compiler.
_Avoid_: mGBA, gemba

**Conformance fixture**:
The one kitchen-sink program every backend is run through, which must touch every kind and
every operator. A feature missing from it fails loudly.
_Avoid_: golden test, smoke test

**Differential test**:
Running the same program on two backends and comparing what they did — behavioural
agreement, as opposed to the fixture's coverage.
_Avoid_: parity test, cross-check

**Lowering run**:
One play of the whole test suite for one lowering. `rake test` is a run for each: the GBA
lowering's (the interpreter, with the cartridge checked in the emulator) and the native
lowering's (the game as C). Every test plays on both, except a test of one lowering's own
output; a test that needs the cartridge skips on the native run, saying why.
_Avoid_: test pass, suite mode

**Checked run**:
The differential test the native lowering run makes of every test: the game played as C
(a **headless run**, with no window), then on the reference interpreter with the same
buttons, compared on every frame and stopped at the first that differs.
_Avoid_: shadow run, replay check

**Playthrough**:
A finished cartridge played with nobody at the controls, from a script of presses and
waits (`VBlank.playthrough`); two played side by side say where they drift apart. The
presses it made, frame by frame, are its **tape**, and a **moment** is a frame the script
names so a report can point at it.
_Avoid_: bot, macro, recording
