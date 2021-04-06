/* { dg-require-effective-target arm_v8_1m_mve_ok } */
/* { dg-add-options arm_v8_1m_mve } */
/* { dg-additional-options "-O2" } */

#include "arm_mve.h"

int8_t
foo (int8_t a, int8x16_t b, mve_pred16_t p)
{
  return vminvq_p_s8 (a, b, p);
}


int8_t
foo1 (int8_t a, int8x16_t b, mve_pred16_t p)
{
  return vminvq_p (a, b, p);
}


int8_t
foo2 (int32_t a, int8x16_t b, mve_pred16_t p)
{
  return vminvq_p (a, b, p);
}

/* { dg-final { scan-assembler-not "__ARM_undef" } } */
/* { dg-final { scan-assembler-times "vminvt.s8" 3 } } */
