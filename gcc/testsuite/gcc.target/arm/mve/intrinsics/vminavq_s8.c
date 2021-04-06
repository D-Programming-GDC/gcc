/* { dg-require-effective-target arm_v8_1m_mve_ok } */
/* { dg-add-options arm_v8_1m_mve } */
/* { dg-additional-options "-O2" } */

#include "arm_mve.h"

uint8_t
foo (uint8_t a, int8x16_t b)
{
  return vminavq_s8 (a, b);
}


uint8_t
foo1 (uint8_t a, int8x16_t b)
{
  return vminavq (a, b);
}


int8_t
foo2 (uint32_t a, int8x16_t b)
{
  return vminavq (a, b);
}

/* { dg-final { scan-assembler-not "__ARM_undef" } } */
/* { dg-final { scan-assembler-times "vminav.s8" 3 } } */
