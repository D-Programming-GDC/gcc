/* Test the `vst1Q_lanep8' ARM Neon intrinsic.  */
/* This file was autogenerated by neon-testgen.  */

/* { dg-do assemble } */
/* { dg-require-effective-target arm_neon_ok } */
/* { dg-options "-save-temps -O0" } */
/* { dg-add-options arm_neon } */

#include "arm_neon.h"

void test_vst1Q_lanep8 (void)
{
  poly8_t *arg0_poly8_t;
  poly8x16_t arg1_poly8x16_t;

  vst1q_lane_p8 (arg0_poly8_t, arg1_poly8x16_t, 1);
}

/* { dg-final { scan-assembler "vst1\.8\[ 	\]+((\\\{\[dD\]\[0-9\]+\\\[\[0-9\]+\\\]\\\})|(\[dD\]\[0-9\]+\\\[\[0-9\]+\\\])), \\\[\[rR\]\[0-9\]+\(:\[0-9\]+\)?\\\]!?\(\[ 	\]+@\[a-zA-Z0-9 \]+\)?\n" } } */
