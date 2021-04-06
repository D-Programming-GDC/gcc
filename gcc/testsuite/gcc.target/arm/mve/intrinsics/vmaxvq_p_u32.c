/* { dg-require-effective-target arm_v8_1m_mve_ok } */
/* { dg-add-options arm_v8_1m_mve } */
/* { dg-additional-options "-O2" } */

#include "arm_mve.h"

uint32_t
foo (uint32_t a, uint32x4_t b, mve_pred16_t p)
{
  return vmaxvq_p_u32 (a, b, p);
}


uint32_t
foo1 (uint32_t a, uint32x4_t b, mve_pred16_t p)
{
  return vmaxvq_p (a, b, p);
}


uint32_t
foo2 (uint8_t a, uint32x4_t b, mve_pred16_t p)
{
  return vmaxvq_p (a, b, p);
}

/* { dg-final { scan-assembler-not "__ARM_undef" } } */
/* { dg-final { scan-assembler-times "vmaxvt.u32" 3 } } */
