/* { dg-require-effective-target arm_v8_1m_mve_ok } */
/* { dg-add-options arm_v8_1m_mve } */
/* { dg-additional-options "-O2" } */

#include "arm_mve.h"

int16x8_t
foo (int16x8_t a, int16x8_t b, int16_t c)
{
  return vqdmlashq_n_s16 (a, b, c);
}

/* { dg-final { scan-assembler "vqdmlash.s16"  }  } */

int16x8_t
foo1 (int16x8_t a, int16x8_t b, int16_t c)
{
  return vqdmlashq (a, b, c);
}

/* { dg-final { scan-assembler "vqdmlash.s16"  }  } */
