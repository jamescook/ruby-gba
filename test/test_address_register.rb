# frozen_string_literal: true

require "test_helper"

# THE BASE OF THE VARIABLE MEMORY, LEFT IN A REGISTER instead of made again before every
# access. Two things have to hold for that to be safe, and they are tested apart:
#
#   * ASM.disturbs? has to say YES about every instruction that could write the register,
#     and it is allowed to say yes about ones that could not. Getting that backwards does
#     not fail — it sends a load or a store to whatever address happens to be there — so
#     the encodings are checked one at a time, built by the same ASM methods the backend
#     emits, which is what keeps this test from drifting away from the encoder.
#   * The backend has to forget at a label and at a call, because both reach code that
#     was not walked through to get here.
class TestAddressRegister < Minitest::Test
  A = RubyGBA::ASM
  AddressRegister = RubyGBA::IR::Backends::GBA::AddressRegister
  ADDR = RubyGBA::IR::Backends::GBA::ADDR
  BASE = RubyGBA::Constants::IWRAM_START
  # The one instruction this whole change is about: the base put in the address register.
  BASE_LOAD = A.load_immediate(ADDR, BASE)

  def disturbs?(bytes, reg = ADDR) = A.disturbs?(bytes.unpack1("V"), reg)

  # ---- which instructions could change a register ----

  def test_an_instruction_writing_the_register_disturbs_it
    assert disturbs?(A.mov_reg(ADDR, 0)), "a move into it"
    assert disturbs?(A.add_reg(ADDR, 1, 0)), "an add landing in it"
    assert disturbs?(A.ldr(ADDR, 1)), "a load into it"
    assert disturbs?(A.load_immediate(ADDR, BASE)), "the base load itself"
    assert disturbs?(A.mul(ADDR, 0, 1)), "a multiply, which keeps its answer elsewhere"
    assert disturbs?(A.pop(ADDR)), "a pop naming it"
    assert disturbs?(A.load_halfword(ADDR, 1)), "a halfword load into it"
    assert disturbs?(A.mov_reg_lsl_reg(ADDR, 0, 1)), "a shift by a register, landing in it"
  end

  def test_the_ordinary_work_between_two_accesses_leaves_it_alone
    refute disturbs?(A.mov_reg(0, 1)), "a move between other registers"
    refute disturbs?(A.add_reg(0, 1, 0)), "an add"
    refute disturbs?(A.sub_imm(0, 0, 1)), "a subtract"
    refute disturbs?(A.lsl_imm(0, 0, 6)), "a shift"
    refute disturbs?(A.orr_imm(1, 1, 0xF00)), "an or"
    refute disturbs?(A.and_reg(0, 0, 1)), "an and"
    refute disturbs?(A.mvn_reg(0, 1)), "a complement"
    refute disturbs?(A.ldr_offset(0, ADDR, 8)), "a load THROUGH it into another register"
    refute disturbs?(A.str_offset(0, ADDR, 8)), "a store through it"
    refute disturbs?(A.store_halfword(0, 1)), "a halfword store, which keeps nothing"
    refute disturbs?(A.push(0)), "a push"
    refute disturbs?(A.pop(1)), "a pop naming other registers"
    refute disturbs?(A.mul(0, 1, 2)), "a multiply landing elsewhere"
    refute disturbs?(A.smull(0, 1, 2, 3)), "a long multiply landing elsewhere"
    refute disturbs?(A.load_immediate(0, 0x06000000)), "a whole address built in another register"
  end

  def test_a_comparison_keeps_no_answer_so_it_disturbs_nothing
    refute disturbs?(A.cmp_reg(0, 1)), "comparing two registers"
    refute disturbs?(A.cmp_imm(0, 0)), "comparing against a number"
    refute disturbs?(A.tst_imm(0, 1)), "testing bits"
    refute disturbs?(A.cmp_reg_lsr(0, 1, 2)), "comparing against a shifted register"
  end

  # A predicated instruction may or may not run, which is not a distinction worth making:
  # what matters is that it COULD write the register.
  def test_an_instruction_that_might_not_run_still_disturbs_what_it_would_write
    assert disturbs?(A.mov_reg_cond(:gt, ADDR, 0))
    assert disturbs?(A.add_imm_cond(:ls, ADDR, ADDR, 4))
    refute disturbs?(A.rsb_imm_cond(:lt, 0, 0, 0))
  end

  # Control leaving counts, because what it reaches is free to use the register.
  def test_leaving_disturbs_everything
    assert disturbs?(A.bx(1)), "jumping through a register"
    assert disturbs?(A.branch_link(4)), "a call"
    assert disturbs?(A.pop(15)), "a return, which pops into the program counter"
    assert disturbs?(A.add_pc_reg_lsl(0, 4)), "a jump worked out as it runs"
    assert disturbs?(A.swi(0x05 << 16)), "handing over to the console's own routines"
    assert disturbs?(A.ldr(15, 1)), "a load into the program counter"
  end

  # A plain branch is the one control instruction that does not: it writes nothing, and
  # wherever it lands is a label, which is where the backend forgets anyway.
  def test_a_plain_branch_writes_nothing
    refute disturbs?(A.branch(4))
    refute disturbs?(A.branch_cond(:eq, 4))
    refute disturbs?(A.loop_forever)
  end

  def test_it_answers_about_whichever_register_is_asked
    move = A.mov_reg(3, 0)
    assert disturbs?(move, 3)
    refute disturbs?(move, 0)
    refute disturbs?(move, ADDR)
  end

  # ---- what the tracker does with those answers ----

  def test_it_remembers_a_value_until_something_could_change_it
    held = AddressRegister.new(reg: ADDR)
    refute held.holds?(BASE), "it starts out knowing nothing"

    held.now_holds(BASE)
    held.saw(A.add_reg(0, 1, 0))
    assert held.holds?(BASE), "arithmetic elsewhere leaves it be"

    held.saw(A.mov_reg(ADDR, 0))
    refute held.holds?(BASE), "a write to the register itself ends it"
  end

  def test_one_disturbing_instruction_among_several_is_enough
    held = AddressRegister.new(reg: ADDR)
    held.now_holds(BASE)
    held.saw(A.add_reg(0, 1, 0) + A.mov_reg(ADDR, 0) + A.add_reg(0, 1, 0))
    refute held.holds?(BASE)
  end

  def test_it_holds_one_value_at_a_time
    held = AddressRegister.new(reg: ADDR)
    held.now_holds(BASE)
    refute held.holds?(BASE + 0x40), "a different address is a different answer"
  end

  # ---- and what the backend emits because of it ----

  # Count how many times the base is put in the address register inside +func+.
  def base_loads_in(func, &block)
    gba = GBA.new
    gba.lower(dsl_program(&block))
    span = gba.func_ranges.fetch(func)
    gba.code[span].scan(BASE_LOAD).length
  end

  def dsl_program(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def test_a_run_of_variable_work_names_the_base_once
    loads = base_loads_in(:body) do
      screen :bitmap
      a = var :a, 1
      b = var :b, 2
      c = var :c, 3
      func(:body) { c.set(a + b) }
      game_loop { call :body }
    end
    assert_equal 1, loads, "three variables reached one after another want the base once"
  end

  def test_a_branch_makes_the_far_side_name_the_base_again
    loads = base_loads_in(:body) do
      screen :bitmap
      a = var :a, 1
      b = var :b, 2
      func(:body) { (a > 0).then { b.set 1 }.else { b.set 2 } }
      game_loop { call :body }
    end
    assert_equal 3, loads,
                 "the test at the top, and then each arm again — an arm is jumped to, so it " \
                 "cannot lean on what the code before the branch left behind"
  end

  def test_a_call_makes_what_follows_it_name_the_base_again
    with_call = base_loads_in(:body) do
      screen :bitmap
      a = var :a, 1
      b = var :b, 2
      func(:bump) { a.add 1 }
      func(:body) { a.set 1; call :bump; b.set 2 }
      game_loop { call :body }
    end
    without = base_loads_in(:body) do
      screen :bitmap
      a = var :a, 1
      b = var :b, 2
      func(:body) { a.set 1; b.set 2 }
      game_loop { call :body }
    end
    assert_equal 1, without, "two writes in a row want the base once"
    assert_equal 2, with_call, "a routine between them is free to use the register for its own work"
  end

  # ---- and the answers still come out right ----

  def test_a_chain_of_variable_arithmetic_still_works_out
    program = dsl_program do
      screen :bitmap
      a = var :a, 5
      b = var :b, 7
      c = var :c, 0
      d = var :d, 0
      func(:sums) { c.set(a + b); d.set(c * a); c.set(d - b) }
      game_loop { call :sums; halt }
    end
    run = Reference.new.run(program)
    assert_equal 53, run[:c], "(5 + 7) * 5 - 7"
    assert_equal 60, run[:d]
  end
end
