/*
 * Reads one calculation per line, "name a b c", and prints each answer on a line of its own,
 * so test_int32_helpers.rb can put thousands of them through rg_int32.h for one compile.
 * b and c are read whether or not the helper takes them.
 */
#include <stdio.h>
#include <string.h>
#include "rg_int32.h"

static int32_t calculate(const char *name, int32_t a, int32_t b, int32_t c) {
  if (strcmp(name, "add") == 0) return rg_add(a, b);
  if (strcmp(name, "sub") == 0) return rg_sub(a, b);
  if (strcmp(name, "mul") == 0) return rg_mul(a, b);
  if (strcmp(name, "neg") == 0) return rg_neg(a);
  if (strcmp(name, "abs") == 0) return rg_abs(a);
  if (strcmp(name, "clamp") == 0) return rg_clamp(a, b, c);
  if (strcmp(name, "div") == 0) return rg_div(a, b);
  if (strcmp(name, "mod") == 0) return rg_mod(a, b);
  if (strcmp(name, "mul_fix") == 0) return rg_mul_fix(a, b, c);
  if (strcmp(name, "div_fix") == 0) return rg_div_fix(a, b, c);
  if (strcmp(name, "bit_and") == 0) return rg_and(a, b);
  if (strcmp(name, "bit_or") == 0) return rg_or(a, b);
  if (strcmp(name, "bit_xor") == 0) return rg_xor(a, b);
  if (strcmp(name, "bit_not") == 0) return rg_not(a);
  if (strcmp(name, "shift_left") == 0) return rg_shl(a, b);
  if (strcmp(name, "shift_right") == 0) return rg_shr(a, b);
  if (strcmp(name, "lt") == 0) return rg_lt(a, b);
  if (strcmp(name, "le") == 0) return rg_le(a, b);
  if (strcmp(name, "gt") == 0) return rg_gt(a, b);
  if (strcmp(name, "ge") == 0) return rg_ge(a, b);
  if (strcmp(name, "eq") == 0) return rg_eq(a, b);
  if (strcmp(name, "ne") == 0) return rg_ne(a, b);
  if (strcmp(name, "both") == 0) return rg_both(a, b);
  if (strcmp(name, "either") == 0) return rg_either(a, b);
  if (strcmp(name, "to_byte") == 0) return rg_to_byte(a);
  if (strcmp(name, "to_half") == 0) return rg_to_half(a);
  fprintf(stderr, "int32_harness: no helper called %s\n", name);
  return 0;
}

int main(void) {
  char name[32];
  long long a, b, c;
  while (scanf("%31s %lld %lld %lld", name, &a, &b, &c) == 4) {
    printf("%d\n", (int)calculate(name, (int32_t)a, (int32_t)b, (int32_t)c));
  }
  return 0;
}
