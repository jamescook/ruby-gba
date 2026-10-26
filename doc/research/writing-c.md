# Writing C from the IR: what sits between the tree and the text

2026-10-11

**The question.** `Backends::Native` will lower the same `IR::Node` tree that `Backends::GBA` and
`Backends::Reference` consume into C, compiled by `zig cc` (clang) with SDL3 into one desktop
executable. Every backend must compute exactly what `IR::Int32` computes. C makes several of those
operations undefined or implementation-defined. What layer between the IR and the C text keeps the C
correct, and how do existing compilers that target C (wasm2c, Nim, Zig's C backend, Spinel) do it?
Are LLVM IR, QBE, libgccjit or MIR better targets? Is there a Ruby gem for C syntax trees?

All source quotes below were read from files fetched at a pinned commit (listed in Sources). Anything
not read from a primary source is marked **UNVERIFIED**.

---

## Recommendation

**Write C.** Do not use LLVM's `.ll`, QBE, libgccjit or MIR. None of them removes the guards: `.ll`
still makes `sdiv` by zero and `MIN / -1` undefined, and gives poison for a shift count of 32 or more.
QBE masks shift counts and says nothing about division by zero. The rest of the native build (picture
composition, the mixer, the SDL shell) is hand-written C in any case. So with C the whole build is one
language and one compiler, inlining works between game and runtime, and `lldb` can step through it.
`.ll` text also has no compatibility promise across the LLVM versions that zig upgrades through.

**Correctness lives in a hand-written helper header, not in the emitter.** `rg_int32.h` mirrors
`int32.rb` one function for one function: `rg_add`, `rg_sub`, `rg_mul`, `rg_neg`, `rg_div`, `rg_mod`,
`rg_mul_fix`, `rg_div_fix`, `rg_and`/`rg_or`/`rg_xor`/`rg_not`, `rg_shl`, `rg_shr`, the six
comparisons, and the narrowing a `:byte`/`:half` slot does. This is what every system read does
(wasm2c's macros, `zig.h`, `spinel_rt.h`). Inside the helpers:

- Values are stored as `int32_t`, so a debugger shows the number the game means. Arithmetic is done
  in `uint32_t`, so nothing overflows. That is the wasm2c / zig.h / Spinel pattern.
- Nothing is implementation-defined either. Turning a `uint32_t` back into an `int32_t` uses the
  defined form (memcpy, or the conditional subtraction), which clang compiles to nothing. `>>` of a
  negative uses zig.h's sign-mask trick (`((x ^ m) >> n) ^ m`). This costs nothing, and it means no
  rule depends on clang behaviour we could not find documented.
- `/` and `%` test for a zero divisor and for `MIN / -1` before dividing (wasm2c `DIV_S`/`REM_S`).
  The floored `%` is `zig_mod_i32`'s formula plus Spinel's `b == -1` case: zig's version still
  does a raw `lhs % rhs`, which is undefined for `INT_MIN % -1`.
- Shifts test `0 <= count < 32` the way `Int32.shift_count_in_range?` does. No prior system follows
  this rule, so it is ours to write.
- `mul_fix` and `div_fix` widen to 64 bits. They shift in unsigned or with the sign-mask trick, and
  `div_fix` clamps to the 32-bit range.

**Generated code never writes a C operator on a game value.** It writes only calls to those helpers.
That one rule removes three problems at once:

- **Signedness** is gone, because every operation goes through a helper.
- **Precedence** is gone, because a call has no precedence.
- **Short-circuiting** is gone. IR `and`/`or` evaluate both sides in Reference (`eval_binop` gets both
  values already worked out), and C's `&&` would skip the right side. `rg_and(a, b)` cannot.

Evaluation order of call arguments is unspecified in C. That is safe only because every IR value kind
is pure today: a random draw is a statement, not a value. The lowering keeps an explicit list of the
value kinds it lowers, so a new kind with a side effect fails loudly and is not silently reordered.

**Between the IR and the text: a very small C syntax tree in Ruby.** The prior art all writes text
through a writer. None builds a C tree (see "Findings"). So this choice is ours, and it is cheap only
because the rule above makes the grammar tiny:

- Expressions are just four kinds: an integer literal, a name, the address of a name, and a call.
- Statements are eight or so, and top-level declarations about five (listed under "Proposed shape").

One printer turns the tree into text and owns everything that is easy to get wrong by hand:
- integer literals (`INT32_MIN` cannot be written `-2147483648`)
- identifiers (IR names like `__bg_x_set` are reserved in C)
- string escaping and comment escaping (`*/`)
- indentation

No lowering method returns a String, and there is no raw-text node, so string-template C cannot creep
in. All hand-written C lives in the runtime files, never in Ruby.

**No `-fwrapv`.** It is pointless once arithmetic is unsigned, and UBSan's overflow check stays on
under it anyway. Generated C is compiled with
`-std=c11 -Wall -Wextra -Wconversion -Wsign-conversion -Werror`. The two conversion warnings turn any
narrowing that slips past a helper into a build error.

**Proof is by running, never by golden C.** Three layers:
1. The helper header against `Int32` itself.
2. The printer against compiled output.
3. The lowering against `Backends::Reference` through the conformance fixture.

Each layer is built twice. One build uses `zig cc -O0`, which turns UBSan fully on with no extra
flags; `-fno-sanitize-recover=all` makes a finding fail the test. The other uses `-O2`, because the
optimizer is what turns hidden undefined behaviour into wrong answers.

### Divide by zero follows the cartridge (decided 2026-10-11)

Today the backends give three answers:

| | Reference | Cartridge | C |
|---|---|---|---|
| `x / 0` | raises `ZeroDivisionError` | 1 or -1, by the numerator's sign (`divide.rb` L430-438) | undefined |
| `x % 0` | raises `ZeroDivisionError` | `x` (the divide routine leaves the numerator over and `emit_modulo` adds 0) | undefined |
| `div_fix` by 0 | raises `ZeroDivisionError` | the same raw 1 or -1: the smallest fraction, not 1.0 (`emit_divide_fix_routine` branches to `emit_divide_by_zero`, L358-359) | undefined |

**Native gives the cartridge's answer.** Generated C never contains a `/` or `%`. It calls `rg_div`,
`rg_mod` and `rg_div_fix`, and each tests for a zero divisor and returns what the console's routine
returns. The answer key still raises, so a program that divides by zero cannot be compared until
`Int32` gives the cartridge's answer too. That change belongs to the main backends and is tracked as
its own piece of work. Until it lands, the native tests do not divide by zero.

Reading a list out of range is a different case. Reference raises, and what the cartridge does has
not been checked. Native stops with the game's source line (`rg_fault`) until that is settled.

---

## Proposed shape of the C emitter (for approval; no code written)

```
lib/vblank/ir/backends/native.rb            Backends::Native: program -> C source. The comment atop
                                              it records the decisions above.
lib/vblank/ir/backends/native/c.rb          The C syntax tree (Data classes, frozen):
                                                expressions  Int, Name, AddressOf, Call
                                                statements   Eval (a call as a statement), Assign,
                                                             If, While, For, Break, Return, Block,
                                                             Comment (carries Node#source)
                                                top level    Global, ConstArray (tables, art),
                                                             Function, FunctionTable (call_one_of),
                                                             Include
lib/vblank/ir/backends/native/printer.rb    The only place text is made. Literals, indentation,
                                              escaping, one line per statement, /* pong.rb:42 */
                                              comments (and #line behind a switch).
lib/vblank/ir/backends/native/names.rb      IR name -> C identifier. A prefix per namespace
                                              (v_ variable, f_ routine, l_ list, t_ table, ...),
                                              bytes outside [A-Za-z0-9] escaped, wasm2c-style, so
                                              distinct names stay distinct. A collision or a
                                              reserved word is a LoweringError. A Name node can only
                                              be made here.
lib/vblank/ir/backends/native/values.rb     One method per value kind, as a VALUES table like
                                              Reference's; each returns a C expression, almost
                                              always a Call to an rg_ helper.
lib/vblank/ir/backends/native/statements.rb One method per statement kind (STATEMENTS table);
                                              each returns C statements. Control flow maps straight:
                                              if/else, repeat -> for with the count read once and
                                              stop_when tested before the body, case -> an if-chain
                                              on a snapshot that runs every clause that matches
                                              (as Reference's exec_case does), wait_vblank -> a
                                              call into the runtime, which takes the frame.
lib/vblank/ir/backends/native/runtime/rg_int32.h     Hand-written; mirrors int32.rb.
lib/vblank/ir/backends/native/runtime/rg_runtime.h   The seam the generated code calls (frames,
                                                       buttons, drawing, sound, saving). With
                                                       rg_int32.h and rg_list.h (the game's
                                                       lists), all game.c includes.
lib/vblank/ir/backends/native/runtime/rg_sdl.c       The SDL3 implementation (later work).
lib/vblank/ir/backends/native/runtime/rg_headless.c  The test and replay implementation.
```

How large: the tree, printer and names come to a few hundred lines of Ruby, and `rg_int32.h` to about
150 lines of C. Building with zig, the screen and the sound runtime are each their own piece of work.
The emitter does not depend on any of them.

### Where SDL sits

**The generated C never names SDL.** The game calls the runtime through one header, `rg_runtime.h`,
which covers frames, buttons, drawing, sound and saving. `rg_runtime.c` answers those calls by
handing each to a DRIVER (`rg_driver.h`), picked when the program starts. There are two:

- **`rg_sdl.c`, the window.** It owns `main()` in the build people play: it opens the window and then
  calls the game's entry routine. Its `wait_vblank` is where SDL is driven, once per console frame:
  - Show the 240x160 picture. It goes into a streaming texture, scaled up by a whole number with
    nearest-neighbour, in the console's own 15-bit colours (`SDL_PIXELFORMAT_XBGR1555`).
  - Pump SDL's events and read the keyboard into the held buttons.
  - Hand the frame's mixed sound to an `SDL_AudioStream` (not yet; sound is its own piece of work).
  - Wait on its own clock until the next console frame (about 59.73 a second), not the monitor's
    refresh.
- **`rg_headless.c`, no window**, for tests and fast replay. It reads the held buttons for
  each frame from standard input, prints each frame's picture and variables for the comparison with
  Reference, and never sleeps.

**The build people play carries both.** `./pong` opens the window; `./pong --headless FRAMES` runs the
windowless driver, so a test can drive the very program a player runs. The tests themselves build
with the windowless driver alone (`rg_headless_main.c` is that build's `main()`), with zig's compiler
and no SDL, which keeps them quick and off the network.

**The game owns the loop, so SDL3's callback entry points do not fit.** `wait_vblank` can sit deep
inside a routine: a program with no `game_loop`, or one built with `frame_sync: :manual`. So the game
cannot hand control back to a host loop each frame. Instead SDL is driven from inside
`rg_wait_vblank`, the same way Reference's `advance_frame` is an ordinary call. SDL3's
`SDL_MAIN_USE_CALLBACKS` / `SDL_AppIterate` model would need the host to call the game once a frame,
which would take coroutines. The build uses SDL3's ordinary `main` instead. The game runs on the main
thread, which is where macOS wants events handled.

**Checked against SDL 3.4.18's headers and at run time (2026-10-11):**
`SDL_PIXELFORMAT_XBGR1555` has red in bits 0-4 (masks R=001f, G=03e0, B=7c00);
`SDL_SetRenderLogicalPresentation(r, 240, 160, SDL_LOGICAL_PRESENTATION_INTEGER_SCALE)`;
`SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_NEAREST)`;
`SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, {SDL_AUDIO_S8, 1, 8192}, NULL, NULL)`
is accepted by CoreAudio and by the dummy driver; `SDL_GetKeyboardState` indexed by
`SDL_SCANCODE_*`; `SDL_GetTicksNS` and `SDL_DelayPrecise`. An ordinary `main` that pumps events
from its own loop works on macOS (`SDL_main.h` defines nothing there; include it in `rg_sdl.c`
only, for Windows's sake), and `SDL_INIT_VIDEO` and event pumping must stay on main()'s thread.

**mGBA's default keys**, the same in its SDL and Qt front ends (mgba `143adf5a`,
`src/platform/sdl/sdl-events.c:188-198`, `src/platform/qt/InputController.cpp:64-73`): arrows for
the pad, X = A, Z = B, A = L, S = R, Return = Start, Backspace = Select.

This split also keeps the emitter testable with no window: every emitter test links the headless
runtime.

**Tests, all under `rake test:native` and none under `rake test`:**

- `test_int32_helpers.rb` compiles one harness. It runs every helper over the cross product of edge
  values (0, ±1, `MIN`, `MIN+1`, `MAX`, powers of two, shift counts -1, 0, 31, 32, 33), plus seeded
  random pairs, and compares each answer with `Int32`. It runs at `-O0` with UBSan on and at `-O2`.
  This test is the contract between the two languages.
- `test_printer.rb` checks behaviour, not text. Every edge literal is printed into a C program that
  prints it back. A corpus of awkward IR names (taken from the examples' real programs, plus
  generated ones) must compile under `-Wreserved-identifier -Werror` and come out distinct.
- `test_native_conformance.rb` runs the conformance fixture: it must cover every portable
  kind, and its variables after N frames must match Reference's. Built at `-O0` with UBSan and at
  `-O2`.

To keep compile time down, each test puts all its cases into one C file and compiles once.

---

## What the IR asks of C

Line numbers are `lib/vblank/ir/int32.rb` at the current `native-backend` head.

| Int32 rule (int32.rb) | C problem it collides with | wasm2c | zig.h / Zig C backend | Nim | Spinel |
|---|---|---|---|---|---|
| `add`/`sub`/`mul` wrap at 2^32 (L39-54) | signed overflow is UB (C23 Annex J.2: "An exceptional condition occurs during the evaluation of an expression (6.5.1)") | every i32 is a `u32`; emits plain `+=` on `u32` | `zig_addw_i32` etc. compute in `zig_promoted_u32` (unsigned) and convert back | `+%` is `cast[int](cast[uint](x) + cast[uint](y))`; plain `+` is checked or, with checks off, raw signed C `+` | wrap mode: `((sp_int)((uintptr_t)(a) + (uintptr_t)(b)))` |
| `neg` wraps, so `-INT_MIN == INT_MIN` (L171-173) | `-INT_MIN` is signed overflow, UB | no neg op in wasm; `0 - x` on `u32` | `zig_abs_i32` uses `zig_subw_i32` | checked: compares to `firstOrd` and raises | `((sp_int)((uintptr_t)0 - (uintptr_t)(a)))` |
| `div` truncates toward zero (L181-187) | `/` already truncates (C99+), but `x / 0` UB and `INT_MIN / -1` UB | `DIV_S`: traps on 0 and on MIN/-1 | C backend emits plain `/`; Zig's Sema inserts safety checks before codegen | codegen tests `b == 0` and raises; `nimDivInt` reports MIN/-1 as overflow | `sp_idiv`: raises on 0; MIN/-1 raises (or returns `a` in wrap mode) |
| `div` by 0: `Int32.div` raises Ruby `ZeroDivisionError` from `a.abs / b.abs` (L184); the GBA backend returns ±1 by the numerator's sign (`backends/gba/divide.rb` L430-438) | UB in C | traps | (Sema check) | raises `DivByZeroDefect` | raises `ZeroDivisionError` |
| `div` of `INT_MIN` by `-1`: wraps to `INT_MIN` (L186, `wrap(2**31)`) | UB in C (N3220 6.5.6: "otherwise, the behavior of both a/b and a%b is undefined"); traps on x86 **UNVERIFIED** | traps (`INT_OVERFLOW`) | (Sema check) | raises overflow | wrap mode returns `a` (= MIN), matching Int32 |
| `mod` is Ruby's floored modulo, `-1 % 64 == 63` (L203-209) | C `%` truncates (sign of dividend); `% 0` UB; `INT_MIN % -1` UB | `REM_S` is truncated; MIN % -1 returns 0 | `zig_mod_i32` is floored (formula below) | `mod` is truncated (`-7 mod 5 == -2`) | `sp_imod` is floored; `b == -1` returns 0 |
| `mod` by 0 raises (L206, explicit) | UB | traps | (Sema) | raises | raises |
| `mul_fix`: 64-bit product, then `>> bits` flooring, then wrap (L71-73) | `>>` of a negative is implementation-defined; int64 → int32 conversion of an out-of-range value is implementation-defined (N3220 6.3.1.3) | n/a | `zig_shr_i64` avoids implementation-defined `>>` | n/a | n/a |
| `div_fix`: `a << bits` widened, truncating divide, then **clamped** to the int32 range (L94-100) | left shift of a negative value is UB even in C23 (N3220 6.5.8p4); divisor 0 UB | n/a | n/a | n/a | n/a |
| bit `& \| ^ ~` (L110-124) | none in practice; C23 mandates two's complement (N2412) | plain operators on `u32` | `zig_and_i32` etc. are plain operators | plain operators | plain operators |
| `<<` count outside 0...32 gives 0; in range wraps (L140-144) | count ≥ width or < 0 is UB; signed `<<` into or past the sign bit is UB | **masks** the count (`& 31`) on `u32` | count is `uint8_t`, Zig's type system bounds it; `zig_shlw_i32` shifts in unsigned | **masks** the count (`& (k-1)`), shifts in unsigned | `sp_int_shl`: count ≥ width → 0 (wrap mode), shifts in unsigned; **negative count reverses direction** |
| `>>` count outside 0...32 gives 0 or -1 (L159-163); a negative count does NOT reverse (L132-136) | count UB as above; `>>` of a negative is implementation-defined | **masks** the count; `(s32)x >> n` relies on arithmetic `>>` | `zig_shr_i32` uses an xor sign mask, so no implementation-defined `>>` | **masks** the count; `mAshrI` relies on arithmetic `>>` | `sp_int_shr`: count ≥ width → 0 or -1 (same as Int32); negative count reverses |
| `cmp` signed (L214-216) | none if operands are signed | casts each `u32` to `s32` before `<` | n/a | n/a | n/a |
| narrow list/pool slots `:byte`/`:half` (dsl-reference) | `int16 * int16` promotes to `int` and can overflow (UB); storing an out-of-range value into `int8_t` is implementation-defined | n/a | `zig_promoted_T` exists for exactly this: "implements C integral promotions except with signedness preserved, which allows wrapping operations to avoid the ub" (zig.h L774-775) | n/a | n/a |

Fixed point: `DEFAULT_BITS = 16` (`lib/vblank/dsl/fraction.rb` L78). With 16 bits, `|a * b| ≤ 2^62`
and `|a << 16| ≤ 2^47`, so both intermediates fit `int64_t`; the hazards are the shift of a negative
`int64_t` and the narrowing, not width.

Two things no prior system shares with this IR, so no helper can be copied as is:

- **Shift counts saturate instead of being masked or reversed.** wasm2c and Nim mask (`& 31`), which
  gives `x << 33 == x << 1`; Int32 gives 0. Spinel saturates but reverses on a negative count; Int32
  does not.
- **`div` by zero has two answers today.** The Reference raises; the GBA lowering returns ±1 with the
  numerator left over. A third backend has to pick one, and the conformance fixture should pin it.

---

## wasm2c (WebAssembly/wabt)

Commit `e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3`.

**Arithmetic is done on unsigned types; no `-fwrapv`.** Each wasm `i32` is written as `u32`
(`c-writer.cc` L1282: `case Type::I32: return "u32";`, and `typedef uint32_t u32;` in the generated
header). `i32.add` becomes an infix `+=` on two `u32` locals (`c-writer.cc` L4466-4471, L4430-4443).
The golden test `test/wasm2c/add.txt` shows the generated body:

```c
u32 w2c_test_add_0(w2c_test* instance, u32 var_p0, u32 var_p1) {
  ...
  u32 var_i0, var_i1;
  var_i0 = var_p0;
  var_i1 = var_p1;
  var_i0 += var_i1;
```

The README's compile notes ask for `-fno-optimize-sibling-calls -frounding-math` (and GCC
`-fsignaling-nans`) for conformance, and nothing for integers (`wasm2c/README.md` L119-128). The spec
runner compiles with `-O3 -Wall -Werror` and no `-fwrapv` (`test/run-spec-wasm2c.py` L451-475).

**Division and remainder go through macros** (`src/template/wasm2c.declarations.c` L416-429):

```c
#define DIV_S(ut, min, x, y)                                  \
  ((UNLIKELY((y) == 0))                  ? TRAP(DIV_BY_ZERO)  \
   : (UNLIKELY((x) == min && (y) == -1)) ? TRAP(INT_OVERFLOW) \
                                         : (ut)((x) / (y)))

#define REM_S(ut, min, x, y)                                 \
  ((UNLIKELY((y) == 0))                  ? TRAP(DIV_BY_ZERO) \
   : (UNLIKELY((x) == min && (y) == -1)) ? 0                 \
                                         : (ut)((x) % (y)))

#define I32_DIV_S(x, y) DIV_S(u32, INT32_MIN, (s32)x, (s32)y)
#define I32_REM_S(x, y) REM_S(u32, INT32_MIN, (s32)x, (s32)y)
```

`TRAP(x)` is `(wasm_rt_trap(WASM_RT_TRAP_##x), 0)` (L73).

**Shifts are emitted inline with a masked count** (`c-writer.cc` L4533-4556):

```cpp
case Opcode::I32Shl:
  Write(StackVar(1), " <<= (", StackVar(0), " & ",
        GetShiftMask(expr.opcode.GetResultType()), ");", Newline());
...
case Opcode::I32ShrS: {
  Write(StackVar(1), " = (", type, ")((", SignedType(type), ")",
        StackVar(1), " >> (", StackVar(0), " & ", GetShiftMask(type), "));",
```

`GetShiftMask` returns 31 for `I32` (L178). `shl` is a `u32` shift, so it is defined. `shr_s` converts
`u32` to `s32` (implementation-defined for values above `INT32_MAX`) and shifts a possibly negative
`s32` (implementation-defined). GCC documents both as modular and sign-extending ("For conversion to
a type of width N, the value is reduced modulo 2^N"; "Signed '>>' acts on negative numbers by sign
extension"). Signed comparisons use `WriteSignedBinaryExpr`, which casts both operands to the signed
type (L4453-4462, L4948-4950).

**Rotates** are macros on the unsigned value with masked counts (L436-445):

```c
#define ROTL(x, y, mask) \
  (((x) << ((y) & (mask))) | ((x) >> (((mask) - (y) + 1) & (mask))))
```

**Float to int** checks NaN and range before converting (L461-473), for example
`TRUNC_S(u32, s32, f32, (f32)INT32_MIN, >=, 2147483648.f, x)`, trapping `INVALID_CONVERSION` or
`INT_OVERFLOW`. Saturating variants (`TRUNC_SAT_S`) return the min/max instead (L485-516).

**Text, not a tree.** `CWriter` writes straight to a `Stream*` through a variadic template
(`c-writer.cc` L324-329: `Write(T&& t, U&& u, Args&&... args)` writes each argument in turn). It keeps
a type stack (`PushType`/`DropTypes`) so it knows each stack slot's C type, and each wasm instruction
becomes one C statement on numbered locals (`var_i0`, `var_i1`). Output is one header plus one or more
`.c` files; with `--num-outputs N` functions are spread across N streams (L3066-3071) so big modules
compile in parallel.

**Names.** Global symbols get the prefix `w2c_`, locals `var_`, runtime helpers `wasm2c_`
(L563-566). `Mangle` (L814-901) escapes every non-alphanumeric byte as `0xAB`, escapes an underscore at
the start, at the end or after another underscore, and escapes hex digits following `0x`, so distinct
wasm names map to distinct C names. Collisions are resolved by `FindUniqueName`, which appends `_0`,
`_1`, … (L937-948).

**Testing.** Two kinds. A few golden tests compare the generated C text (`test/wasm2c/add.txt`,
`;;; TOOL: run-wasm2c`). The bulk are the official spec `.wast` files: `run-spec-wasm2c.py` converts
them with `wast2json`, writes a C `main` full of `ASSERT_RETURN`/`ASSERT_TRAP` calls, compiles the
generated C with the runtime, runs it, and checks the pass count (`test/wasm2c/spec/address.txt`:
`255/255 tests passed.`).

---

## Nim's C backend

Commit `51746cb6c0bbe20fb3ac7c401893435549092926` (devel).

**Text through string builders.** "Ropes are mapped to `string` directly nowadays"; `Rope* = string`
(`compiler/ropes.nim` L10, L22). Newer code goes through a `Builder` (`compiler/cbuilderbase.nim`
L3-7: `Snippet* = string`, `Builder* = object buf*: string; indents*: int`). Expression helpers return
strings: `cCast(typ, value) = "((" & typ & ") " & value & ")"` (`cbuilderexprs.nim` L49-50) and
`cOp(binOp: TypedBinaryOp, t, a, b) = '(' & a & ' ' & typedBinaryOperators[binOp] & ' ' & b & ')'`
(L242-243). The typed `cOp` takes the C type `t` and ignores it today; comments such as
`# needs manipulation of t in nifc` (L2) and `# used for expression group, no-op on sexp` (L53) show the
builder was introduced so the same codegen can also emit NIFC, Nim's structured intermediate format.
It is still strings, not a tree.

**Overflow.** With overflow checks on, `+ - * div mod` call compiler procs through
`binaryArithOverflowRaw` and raise on a `true` return (`ccgexprs.nim` L627-656, L658-708). In
`lib/nimbase.h` (L588-620) those procs are the GCC/clang builtins:

```c
#define nimModInt(a, b, res) (((*res) = (a) % (b)), 0)
...
#if NIM_INTBITS == 32
  ...
  #define nimAddInt(a, b, res) __builtin_sadd_overflow(a, b, res)
  #define nimSubInt(a, b, res) __builtin_ssub_overflow(a, b, res)
  #define nimMulInt(a, b, res) __builtin_smul_overflow(a, b, res)
```

The portable fallback (`lib/system/integerops.nim` L42-50) computes in unsigned and tests signs:

```nim
let r = cast[T](cast[U](a) + cast[U](b))
if (r xor a) >= T(0) or (r xor b) >= T(0):
  res[] = r
else:
  result = true
```

Division by zero is tested in generated code before the call (`ccgexprs.nim` L686-696, raising
`raiseDivByZero`); `nimDivInt` reports `low(T) div -1` as overflow (`integerops.nim` L113-121).

**With checks off, Nim emits raw signed C operators**: `cCast(typ, cOp(opr[m], typ, rdLoc(a),
rdLoc(b)))` (`ccgexprs.nim` L678-681). Overflow is then C UB. Nim's default config adds no `-fwrapv`
(`config/nim.cfg`: only `-fno-strict-aliasing` among the relevant flags; a block that would add
`-fsanitize=null -fsanitize-undefined-trap-on-error` is guarded by `@if false:` with the comment "this
does not work yet", L96-99).

**Wrapping operators** go through unsigned: `` `+%`*(x, y: int): int = cast[int](cast[uint](x) +
cast[uint](y)) `` (`lib/system/arithmetics.nim` L362-367). `div` truncates and `mod` follows the
dividend (`-7 mod 5 == -2`, L115-123), i.e. not Ruby's `%`.

**Shifts mask the count** (`ccgexprs.nim` L763-776): `shr` is
`cCast(t, cOp(Shr, at, cCast(at, ra), cOp(BitAnd, at, cCast(bt, rb), cIntLiteral(k - 1))))` with
`at` unsigned; `shl` is the same on unsigned; `ashr` uses a signed `at`, so it relies on arithmetic
`>>`.

**`#line`.** With `--lineDir:on`, `genCLineDir` writes `"\n#line " & $line & " FX_" & $fileIdx.int32 &
"\n"` (`compiler/cgen.nim` L549-563), with `FX_n` defined as file names elsewhere.

---

## Zig's C backend (`-ofmt=c`)

Zig moved to Codeberg; the GitHub repo description is "Moved to Codeberg". Commit
`eee0e6d70e8b4987a608fc1ea9451fcaf9dd6d16`.

**Wrapping helpers in `lib/zig.h`**, generated per width by `zig_int_operators(w)` (L944-1052):

```c
static inline uint##w##_t zig_addw_u##w(uint##w##_t lhs, uint##w##_t rhs, uint8_t bits) {
    return zig_u##w##_truncate_u##w((zig_promoted_u##w)lhs + rhs, bits);
}
static inline int##w##_t zig_addw_i##w(int##w##_t lhs, int##w##_t rhs, uint8_t bits) {
    return zig_i##w##_bitCast_u##w(zig_addw_u##w(zig_u##w##_bitCast_i##w(lhs, bits),
                                   zig_u##w##_bitCast_i##w(rhs, bits), bits), bits);
}
```

`zig_promoted_u32` is `unsigned int` where that holds 32 bits (L825-826); the comment at L774-775
says the promoted types exist "to avoid the ub that would be caused by the normal promotion".

**Arithmetic right shift without implementation-defined `>>`** (L955-958):

```c
static inline int##w##_t zig_shr_i##w(int##w##_t lhs, uint8_t rhs) {
    int##w##_t sign_mask = lhs < INT##w##_C(0) ? -INT##w##_C(1) : INT##w##_C(0);
    return ((lhs ^ sign_mask) >> rhs) ^ sign_mask;
}
```

**Floored division and modulo** (L971-973, L1003-1006), the formula Ruby's `%` needs:

```c
static inline int##w##_t zig_divFloor_i##w(int##w##_t lhs, int##w##_t rhs) {
    return lhs / rhs + (lhs % rhs != INT##w##_C(0) ? zig_shr_i##w(lhs ^ rhs, UINT8_C(w) - UINT8_C(1)) : INT##w##_C(0));
}
static inline int##w##_t zig_mod_i##w(int##w##_t lhs, int##w##_t rhs) {
    int##w##_t rem = lhs % rhs;
    return rem + (rem != INT##w##_C(0) ? rhs & zig_shr_i##w(lhs ^ rhs, UINT8_C(w) - UINT8_C(1)) : INT##w##_C(0));
}
```

`zig_shlw_i32` shifts in unsigned (L1012-1014). The shift count is a `uint8_t`; Zig's type system
bounds it below the width, so zig.h does not mask or test it.

**Division is not guarded in C.** `src/codegen/c.zig` L2803-2818: `.div_trunc, .div_exact =>
airBinOp(f, inst, "/", "divTrunc", ...)`, `.rem => airBinOp(f, inst, "%", "rem", ...)`, `.mod =>
airBinBuiltinCall(f, inst, "mod", ...)`. Plain `+ - *` are also emitted as C operators, with
`// TODO use a different strategy for add, sub, mul, div that communicates to the optimizer that
wrapping is UB.` (L2795-2799). Overflow and division by zero are illegal behavior in Zig itself, and
the safety checks are inserted before C generation (by Sema, in safe modes) **UNVERIFIED: not read in
Sema.zig**. `.add_wrap`/`.sub_wrap`/`.mul_wrap` map to `addw`/`subw`/`mulw` (L2821-2823); `.shl`
maps to `shlw`, `.shr` to `shr` (L2874-2876).

**Text through a writer.** `airBinOp` writes `local = lhs op rhs;` with `w.writeAll`/`w.writeByte`
into `f.code.writer` (L3715-3760): one C local per AIR instruction. `src/link/C.zig` L1-4: "we
individually generate each declaration (NAV), and the output is stitched together (alongside types and
UAVs) in an appropriate order in `flush`", into one output file.

**Names.** `formatIdentOptions` (c.zig L436-452) keeps `[A-Za-z_]`, turns `.` and space into `_`,
writes any other byte (and a leading digit) as `_` plus two hex digits, and prefixes `zig_e_` when
`isReservedIdent` matches: a C keyword or library name from a table, anything starting `_` plus an
uppercase letter or `_`, or the prefixes `zig_`, `enum__`, `bitpack__`, `aligned__`, `fn__`
(L404-426).

**Testing.** The behavior test suite is compiled to C, then the C is compiled with `-std=c99 -Werror
-Wall -Wextra ...` and run (`test/tests.zig` L2813-2870).

---

## Spinel (Ruby → C, github.com/matz/spinel)

Commit `a0593c42fc771b4b17ffe6601fdb4b25113cf407`. The compiler on `master` is written in C ("the
earlier self-hosting Ruby implementation is preserved on the `self-host` branch", `src/README.md`).

**Text.** Code generation calls `buf_printf`/`buf_puts` on byte buffers, for example
`buf_printf(b, "sp_idiv(%s, ", r); emit_int_divisor(c, argv[0], b); buf_puts(b, ")");`
(`src/codegen_call_recv.c` L8735). Builtin methods are a table of C string templates with `$r`
placeholders: `{ TY_INT, "succ", ..., BOPE_TEMPLATE, "sp_int_add(($r), 1)" }`
(`src/builtin_ops.c` L1521). It emits `#line %d "%s"` directives (`src/codegen_stmt.c` L11401).

**Overflow modes** (`docs/int-overflow.md`): `--int-overflow=raise` (default, `RangeError`), `wrap`,
`promote` (bignum, experimental). `sp_int` is `intptr_t`, so 32 bits on a 32-bit target. The
driver passes `-DSP_INT_OVERFLOW_MODE_{RAISE,WRAP,PROMOTE}` (`src/main.c` L768-770) and no `-fwrapv`
(compile command L1125-1140). Wrap mode (`lib/spinel_rt.h` L336-345):

```c
#ifdef SP_INT_OVERFLOW_MODE_WRAP
/* computed in the unsigned counterpart, as sp_int_c_add and the rest below:
   signed overflow is undefined behaviour, which an optimizing C compiler
   may assume never happens, and wrap mode is a promise about exactly that
   overflow (gcc -O1 and up answered -2**63 * 2 as -2**63, not 0) */
#  define sp_int_add(a, b) ((sp_int)((uintptr_t)(a) + (uintptr_t)(b)))
#  define sp_int_sub(a, b) ((sp_int)((uintptr_t)(a) - (uintptr_t)(b)))
#  define sp_int_mul(a, b) ((sp_int)((uintptr_t)(a) * (uintptr_t)(b)))
#  define sp_int_neg(a)    ((sp_int)((uintptr_t)0 - (uintptr_t)(a)))
```

Raise mode uses `sp_ckd_add_iptr`, which is `__builtin_add_overflow`, else C23 `ckd_add` from
`<stdckdint.h>`, else a hand range check (`lib/sp_compat.h` L222-253). The same header comment
(spinel_rt.h, just above L336) records that an inline-function variant "produced wrong optcarrot
output ... apparently from a UB-assumption interaction", which is why these are statement-expression
macros.

**Ruby division and modulo** (`lib/spinel_rt.h` L223-256):

```c
static inline sp_int sp_idiv(sp_int a, sp_int b) {
  if (b == 0) sp_raise_cls("ZeroDivisionError", "divided by 0");
  if (SP_UNLIKELY(b == -1 && a == INTPTR_MIN)) {
#ifdef SP_INT_OVERFLOW_MODE_WRAP
    return a;
#else
    sp_raise_cls("RangeError", "integer overflow in /");
#endif
  }
  sp_int q = a / b; sp_int r = a % b;
  if ((r != 0) && ((r ^ b) < 0)) q--;
  return q;
}
static inline sp_int sp_imod(sp_int a, sp_int b) {
  if (SP_POW2_CONST(b)) return a & (b - 1);
  if (b == 0) sp_raise_cls("ZeroDivisionError", "divided by 0");
  if (SP_UNLIKELY(b == -1)) return 0;   /* -2**63 % -1 traps in C; it is 0 */
  sp_int r = a % b;
  if ((r != 0) && ((r ^ b) < 0)) r += b;
  return r;
}
```

`sp_imod` is exactly Int32's `mod` except for the zero divisor. (`sp_idiv` floors, as Ruby does;
Int32's `div` truncates, so it is not reusable.) The comment at L216-222 notes clang turns the floored
`%` by a constant power of two into a mask and GCC does not, hence the explicit `SP_POW2_CONST` case.

**Shifts** (`lib/spinel_rt.h` L1673-1695): a count ≥ width gives 0 (left, wrap mode) or 0/-1 (right),
the left shift is done on `uintptr_t`, and a negative count shifts the other way. Note the
negative-count branch of `sp_int_shr` is `(a << s)` on a signed `sp_int`, which is UB when `a` is
negative (N3220 6.5.8p4).

**Testing.** A corpus of `.rb` programs with `.expected` output (`test/*.rb.expected`), run in each
overflow mode and as 32-bit programs (`docs/int-overflow.md` L102-117).

---

## Others (brief)

Chicken Scheme, Cython and Vala were skipped for time. **UNVERIFIED** (not checked): all three are
commonly described as emitting C as text.

---

## Alternatives to C

### LLVM IR text (`.ll`)

From `llvm/docs/LangRef.md` (commit `738d73e2`):

- `add`: "If the sum has unsigned overflow, the result returned is the mathematical result modulo
  2^n". With `nsw`, signed overflow gives poison. So plain `add`/`sub`/`mul` already wrap; that part
  is easier than C.
- `sdiv`: "Division by zero is undefined behavior. ... Overflow also leads to undefined behavior;
  this is a rare case, but can occur, for example, by doing a 32-bit division of -2147483648 by -1."
  `srem` has the same two rules and is truncated ("the same sign as the dividend").
- `shl`/`ashr`: "If `op2` is (statically or dynamically) equal to or larger than the number of bits in
  `op1`, this instruction returns a poison value." `ashr` is arithmetic by definition.

So `.ll` removes the add/sub/mul and arithmetic-shift problems but keeps the same division and shift
count guards. Stability: `llvm/docs/DeveloperPolicy.md` "IR Backwards Compatibility": "The textual
format is not backwards compatible. We don't change it too often, but there are no specific
promises." Bitcode is the format kept loadable "since version 3.0".

`zig cc` accepts `.ll`: `classifyFileExt` returns `.ll` for that extension (`src/Compilation.zig`
L7144-7145) and `.ll`/`.bc` are in the list of inputs passed to clang (L6519-6520). clang's driver
lists `TYPE("ir", LLVM_IR, INVALID, "ll", ...)` (`clang/include/clang/Driver/Types.def` L101). The
`.ll` would have to match the LLVM version bundled in the pinned zig release, because the text format
has no compatibility promise.

### QBE (c9x.me/compile)

"QBE is a compiler backend that aims to provide 70% of the performance of industrial optimizing
compilers in 10% of the code." Targets: "amd64 (linux and osx), arm64, and riscv64" (front page);
1.1 (2023-02-01) added `arm64_apple`; 1.3 (2026-06-01) adds "Windows ABI support" (releases page).
It writes assembly and the usage shown is `qbe -o out.s file.ssa && cc out.s`, so it needs an external
assembler and linker; linking SDL3 would happen in that `cc` (or `zig cc`) step.

Semantics (`doc/il.html`, "Arithmetic and Bits"): `div` "is truncated towards zero"; for `rem` "The
sign of the remainder is the same as the one of the dividend"; shifts: "The shifting amount is taken
modulo the size of the result type." The document says nothing about division by zero or `INT_MIN /
-1`. So QBE masks shift counts (not Int32's rule) and leaves division edge cases unstated.

### libgccjit

"an API for embedding GCC inside programs and libraries"; the docs header reads "libgccjit 17.0.0
(experimental)" (gcc.gnu.org/onlinedocs/jit/). The compatibility page says the developers "strive for
ABI and API backward-compatibility". It ships with GCC, not clang, so it would not go through
`zig cc`. Platform support **UNVERIFIED**.

### MIR (vnmakarov/mir)

Last release v1.0.0 (2024-05-27); last push 2026-06-19. README disclaimer: no warranty "on platforms
other than x86_64 Linux/OSX, aarch64 Linux/OSX(Apple M1), and ppc64le/s390x/riscv64 Linux". A CI
badge is named `AMD64-Linux-OSX-Windows-test`. It is a JIT/C-to-MIR toolchain in C; it would be a new
native dependency.

---

## Ruby gems

- **`cast`** — rubygems: 0.4.0 released 2025-01-19 (previous 0.3.1 in 2020), summary "C parser and
  AST constructor.", 55,521 downloads; repo `oggy/cast` not archived, last push 2025-01-19. It parses C
  into `Node` objects and `to_s` returns "the code for the tree" (README L160). It has a C extension
  (`ext/cast.c`, `ext/parser.c`, `ext/yylex.re`), so it needs a compiler at install time.
- Forks: `casty` 0.3.2, `csquare-cast` 0.2.2 (rubygems search). `cgen` 0.16.12, last release
  2013-12-28, is for generating Ruby C extensions. `yadriggy` 1.4.0 (2022-04-12) builds a method's AST
  for embedded DSLs.
- **`ffi-clang`** 0.16.0 (2026-05-02): "Ruby FFI bindings for libclang C interface" — a parser, needs
  libclang, does not generate C.

No maintained pure-Ruby gem for building C syntax trees was found.

---

## Sanitizers and flags

From `clang/docs/UndefinedBehaviorSanitizer.md`:

- `-fsanitize=signed-integer-overflow`: "This includes all the checks covered by `-ftrapv`, as well as
  checks for signed division overflow (`INT_MIN/-1`). Note that checks are still added even when
  `-fwrapv` is enabled."
- `-fsanitize=integer-divide-by-zero`: "Integer division by zero."
- `-fsanitize=shift`: "Shift operators where the amount shifted is greater or equal to the promoted
  bit-width of the left hand side or less than zero, or where the left hand side is negative. For a
  signed left shift, also checks for signed overflow in C". `shift-base` / `shift-exponent` split it.
  Whether "left hand side is negative" applies to `>>` as well as `<<` is **UNVERIFIED**.
- `-fsanitize=undefined` covers all listed checks except `float-divide-by-zero`,
  `unsigned-integer-overflow`, `implicit-conversion`, `local-bounds`, `vptr` and the nullability
  group. `-fsanitize=implicit-conversion` (opt-in) would catch silent narrowing into `int8_t`/`int16_t`
  slots.
- `-fsanitize-trap=...` executes a trap instruction and needs no UBSan runtime.

clang option help text (`clang/include/clang/Options/Options.td`): `-fwrapv` "Treat signed integer
overflow as two's complement" (L5033-5035); `-ftrapv` "Trap on integer overflow" (L4858-4860).

**zig cc:**

- `-O0`/`-Og` select Debug, `-O1`…`-O4`/`-Ofast` select ReleaseFast, `-Os`/`-Oz` ReleaseSmall
  (`src/main.zig` L2334-2352).
- The default for C sanitizing by mode (`src/Module.zig` L260-272): `.debug => .full`, `.safe =>
  .trap`, `.fast, .small => .off`. `.full` adds `-fsanitize=undefined` plus `-fno-sanitize=vptr` and
  `-fno-sanitize=function`; `.trap` adds `-fsanitize-trap=undefined` (`src/Compilation.zig`
  L6526-6566). So a Debug `zig cc` build of the generated C has UBSan on with no extra flags.
- `-fsanitize=undefined` with `-O2` turns ReleaseFast into ReleaseSafe (`main.zig` L3077-3081).
- `-fwrapv` has no special handling in zig's driver (no match in `main.zig`); unrecognized flags are
  forwarded to clang (`.other => try cc_argv.appendSlice(arena, it.other_args)`, L2026-2028).

**C23.** WG14 N2412 (JF Bastien and Jens Gustedt, 2019-08-11), "Two's complement sign representation
for C2x", removes ones' complement and sign-and-magnitude. It lists what C++ went further on —
"Overflowing operations and out-of-range conversion are generally mapped to modulo operations and
cannot trap or raise signals" — and says "WG14 has not yet found consensus for these points, so we
leave them as they are in the current specification." N2218 is the earlier proposal it follows. In
N3220 (working draft after C23, ISO/IEC 9899:2024):

- 6.5.8: count "negative or is greater than or equal to the width of the promoted left operand, the
  behavior is undefined"; `E1 << E2` with signed `E1`: "If E1 has a signed type and nonnegative value,
  and E1 × 2^E2 is representable in the result type, then that is the resulting value; otherwise, the
  behavior is undefined"; `E1 >> E2`: "If E1 has a signed type and a negative value, the resulting
  value is implementation-defined."
- 6.5.6: "If the quotient a/b is representable, the expression (a/b)*b + a%b shall equal a; otherwise,
  the behavior of both a/b and a%b is undefined."
- 6.3.1.3: converting to a signed type a value that cannot be represented: "either the result is
  implementation-defined or an implementation-defined signal is raised."
- Annex J.2 still lists "An exceptional condition occurs during the evaluation of an expression
  (6.5.1)" as UB. `<stdckdint.h>` (7.20, checked integer operations) is new in C23.

So C23 changes none of the rules that matter here.

---

## Findings that matter for this repo

- **Every system read builds C as text through a writer or string buffer; none builds a full C
  syntax tree.** wasm2c: variadic `Write` to a `Stream`, plus a type stack. Nim: `Rope = string`, and
  a newer `Builder`/`Snippet` layer of typed helpers (`cOp(Add, t, a, b)`) that is still strings.
  Zig: `std.Io.Writer` per declaration, stitched in `flush`. Spinel: `buf_printf` and string
  templates. The thing between their IR and the text is a **runtime header of helpers** plus a
  **small emitter that only ever writes calls to those helpers or operators on known-safe types**.
- **Nobody relies on `-fwrapv`.** wasm2c, Zig and Spinel compute wrapping arithmetic in the unsigned
  type and convert back; Nim's wrapping operators do the same and its plain operators are raw signed
  C. Spinel's comment records GCC miscompiling signed wrap at `-O1`. Also, UBSan's
  `signed-integer-overflow` check stays on under `-fwrapv`, so a `-fwrapv` design would still trip
  `zig cc` Debug builds. Unsigned arithmetic keeps the generated C free of UB on its own.
- **Every system sends `/` and `%` through a helper that tests the zero divisor and `MIN / -1`**
  (wasm2c `DIV_S`/`REM_S`, Spinel `sp_idiv`/`sp_imod`, Nim's codegen test plus `nimDivInt`), or
  proves them impossible earlier (Zig). The Native backend needs `rg_div`/`rg_mod` helpers,
  and the IR has to settle what `/ 0` returns, since the Reference raises and the GBA lowering returns
  ±1.
- **Ruby's floored `%` has two ready formulas**: `zig_mod_i32` and Spinel's `sp_imod` (with its
  `b == -1 → 0` case). Both match `Int32.mod` for nonzero divisors.
- **No prior helper implements Int32's shift rule.** wasm2c and Nim mask the count; QBE takes it
  modulo the width; Spinel saturates but reverses on negatives; LLVM gives poison. The Native backend
  needs its own `shl`/`shr` helpers with an explicit `count >= 0 && count < 32` test, as `int32.rb`
  L167-169 does.
- **Implementation-defined behavior is a choice, not a hazard, once the toolchain is fixed.** wasm2c
  and Nim rely on arithmetic `>>` and modular narrowing (GCC documents both; clang's equivalent
  documentation was not found). zig.h avoids both with the sign-mask trick. Since `zig cc` is the only
  compiler, relying on clang is defensible; avoiding it costs one xor pair per shift.
- **Narrow slots need care.** `:byte`/`:half` list and pool slots promote to `int`; zig.h's
  `zig_promoted_*` types exist because `int16 * int16` can overflow `int`. Do the arithmetic at 32
  bits unsigned and only narrow on store.
- **Testing is differential everywhere.** wabt runs the official spec assertions through compiled C;
  Zig runs its behavior tests through compiled C with `-Werror`; Spinel runs a program corpus with
  expected output in each overflow mode and at 32 bits. Golden C-text tests are a small minority
  (wabt has a few). Here the oracle already exists: run `test/conformance_fixture.rb` through Native
  and compare with `Backends::Reference`. Building those runs with `zig cc -O0` gets UBSan for free.
- **LLVM `.ll` or QBE do not remove the guards.** `.ll` wraps add/sub/mul for free but keeps division
  UB and shift poison, and its text format has no compatibility promise across the LLVM versions zig
  bundles. QBE masks shifts and is silent on division by zero, needs an external assembler/linker, and
  only gained Windows ABI support in 1.3. libgccjit is GCC-only; MIR is another native dependency.
- **There is no live pure-Ruby C AST gem.** `cast` (0.4.0, 2025) is a parser with a C extension; the
  others are stale or parsers. A small emitter in this repo is the norm, not a gap.

---

## Sources

1. wabt `src/template/wasm2c.declarations.c` —
   https://github.com/WebAssembly/wabt/blob/e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3/src/template/wasm2c.declarations.c#L416-L516
2. wabt `src/c-writer.cc` —
   https://github.com/WebAssembly/wabt/blob/e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3/src/c-writer.cc
   (L178, L324-329, L563-566, L814-948, L1282, L3066-3071, L4430-4556, L4948-4986)
3. wabt `test/run-spec-wasm2c.py` —
   https://github.com/WebAssembly/wabt/blob/e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3/test/run-spec-wasm2c.py#L451-L475
4. wabt `wasm2c/README.md` —
   https://github.com/WebAssembly/wabt/blob/e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3/wasm2c/README.md#L109-L128
5. wabt `test/wasm2c/add.txt` and `test/wasm2c/spec/address.txt` —
   https://github.com/WebAssembly/wabt/tree/e5cc0c4b7c46a322cd1673ffd904c69ae8625ce3/test/wasm2c
6. Nim `compiler/ccgexprs.nim` —
   https://github.com/nim-lang/Nim/blob/51746cb6c0bbe20fb3ac7c401893435549092926/compiler/ccgexprs.nim#L627-L800
7. Nim `lib/nimbase.h` —
   https://github.com/nim-lang/Nim/blob/51746cb6c0bbe20fb3ac7c401893435549092926/lib/nimbase.h#L588-L620
8. Nim `lib/system/integerops.nim` —
   https://github.com/nim-lang/Nim/blob/51746cb6c0bbe20fb3ac7c401893435549092926/lib/system/integerops.nim
9. Nim `lib/system/arithmetics.nim` —
   https://github.com/nim-lang/Nim/blob/51746cb6c0bbe20fb3ac7c401893435549092926/lib/system/arithmetics.nim
10. Nim `compiler/ropes.nim`, `compiler/cbuilderbase.nim`, `compiler/cbuilderexprs.nim`,
    `compiler/cgen.nim` (L549-563), `config/nim.cfg` (L96-99) —
    https://github.com/nim-lang/Nim/tree/51746cb6c0bbe20fb3ac7c401893435549092926/compiler
11. Zig `lib/zig.h` —
    https://codeberg.org/ziglang/zig/src/commit/eee0e6d70e8b4987a608fc1ea9451fcaf9dd6d16/lib/zig.h
    (L774-830, L910-1052)
12. Zig `src/codegen/c.zig` —
    https://codeberg.org/ziglang/zig/src/commit/eee0e6d70e8b4987a608fc1ea9451fcaf9dd6d16/src/codegen/c.zig
    (L192, L404-460, L2795-2876, L3715-3760)
13. Zig `src/link/C.zig` (L1-4), `test/tests.zig` (L2813-2870), `src/Compilation.zig` (L6519-6566,
    L7126-7147), `src/Module.zig` (L260-272), `src/main.zig` (L2026-2028, L2334-2352, L3077-3081) —
    https://codeberg.org/ziglang/zig/src/commit/eee0e6d70e8b4987a608fc1ea9451fcaf9dd6d16
14. GitHub `ziglang/zig` repository metadata ("Moved to Codeberg") — https://github.com/ziglang/zig
15. Spinel `lib/spinel_rt.h` (L216-256, L336-375, L1667-1695) —
    https://github.com/matz/spinel/blob/a0593c42fc771b4b17ffe6601fdb4b25113cf407/lib/spinel_rt.h
16. Spinel `docs/int-overflow.md` —
    https://github.com/matz/spinel/blob/a0593c42fc771b4b17ffe6601fdb4b25113cf407/docs/int-overflow.md
17. Spinel `src/main.c` (L768-770, L1125-1140), `src/README.md`, `src/builtin_ops.c` (L1521),
    `src/codegen_call_recv.c` (L8735), `src/codegen_stmt.c` (L11401), `lib/sp_compat.h` (L222-253),
    `lib/sp_alloc.h` (L1031-1043) —
    https://github.com/matz/spinel/tree/a0593c42fc771b4b17ffe6601fdb4b25113cf407
18. LLVM `llvm/docs/LangRef.md` (`add`, `sdiv`, `srem`, `shl`, `ashr`) —
    https://github.com/llvm/llvm-project/blob/738d73e259e3fbcb31ed531cc82090deaba77257/llvm/docs/LangRef.md
19. LLVM `llvm/docs/DeveloperPolicy.md` "IR Backwards Compatibility" —
    https://github.com/llvm/llvm-project/blob/738d73e259e3fbcb31ed531cc82090deaba77257/llvm/docs/DeveloperPolicy.md
20. clang `clang/docs/UndefinedBehaviorSanitizer.md` —
    https://github.com/llvm/llvm-project/blob/738d73e259e3fbcb31ed531cc82090deaba77257/clang/docs/UndefinedBehaviorSanitizer.md
21. clang `clang/include/clang/Options/Options.td` (L4858-4860, L5033-5035) and
    `clang/include/clang/Driver/Types.def` (L101-102) —
    https://github.com/llvm/llvm-project/tree/738d73e259e3fbcb31ed531cc82090deaba77257/clang/include/clang
22. QBE front page — https://c9x.me/compile/
23. QBE IL reference — https://c9x.me/compile/doc/il.html
24. QBE releases — https://c9x.me/compile/releases.html
25. libgccjit docs — https://gcc.gnu.org/onlinedocs/jit/ and
    https://gcc.gnu.org/onlinedocs/jit/topics/compatibility.html
26. MIR README — https://github.com/vnmakarov/mir/blob/master/README.md ; releases
    https://github.com/vnmakarov/mir/releases
27. rubygems `cast` — https://rubygems.org/api/v1/versions/cast.json ,
    https://rubygems.org/api/v1/gems/cast.json ; repo https://github.com/oggy/cast
28. rubygems search and versions — https://rubygems.org/api/v1/search.json?query=cgen ,
    https://rubygems.org/api/v1/search.json?query=c+ast , https://rubygems.org/api/v1/gems/ffi-clang.json ,
    https://rubygems.org/api/v1/versions/cgen.json , https://rubygems.org/api/v1/versions/yadriggy.json
29. WG14 N2412 — https://www.open-std.org/jtc1/sc22/wg14/www/docs/n2412.pdf
30. WG14 N3220 (ISO/IEC 9899:2024 working draft) —
    https://www.open-std.org/jtc1/sc22/wg14/www/docs/n3220.pdf
31. GCC manual, Integers implementation —
    https://gcc.gnu.org/onlinedocs/gcc/Integers-implementation.html
32. This repo: `lib/vblank/ir/int32.rb`, `lib/vblank/ir/backends/reference.rb` (L2524, L2600-2640,
    L2731-2754), `lib/vblank/ir/backends/gba/divide.rb` (L430-438), `lib/vblank/dsl/fraction.rb`
    (L78), `lib/vblank/ir/nodes.rb`.
