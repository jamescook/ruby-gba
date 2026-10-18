/*
 * Reads one calculation per line, "name a b c", and prints each answer on a line of its own, so
 * test_js_int32_helpers.rb can put thousands of them through runtime/rg_int32.js in one run of
 * node. The runtime file is named on the command line; b and c are read whether or not the
 * helper takes them.
 */
"use strict";

const fs = require("fs");

const runtime = fs.readFileSync(process.argv[2], "utf8");
const helpers = new Function(`${runtime}
  return { add: rg_add, sub: rg_sub, mul: rg_mul, neg: rg_neg, abs: rg_abs, clamp: rg_clamp, div: rg_div,
           mod: rg_mod, mul_fix: rg_mul_fix, div_fix: rg_div_fix, bit_and: rg_and, bit_or: rg_or,
           bit_xor: rg_xor, bit_not: rg_not, shift_left: rg_shl, shift_right: rg_shr, lt: rg_lt, le: rg_le,
           gt: rg_gt, ge: rg_ge, eq: rg_eq, ne: rg_ne, both: rg_both, either: rg_either,
           to_byte: rg_to_byte, to_half: rg_to_half };`)();

const answers = [];
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  if (line.trim() === "") continue;
  const [name, a, b, c] = line.split(" ");
  const helper = helpers[name];
  if (!helper) throw new Error(`int32_harness: no helper called ${name}`);
  answers.push(String(helper(Number(a), Number(b), Number(c))));
}
fs.writeSync(1, `${answers.join("\n")}\n`);
