/* { dg-require-effective-target arm_v8_1m_mve_fp_ok } */
/* { dg-add-options arm_v8_1m_mve_fp } */
/* { dg-additional-options "-O2" } */

#include "arm_mve.h"

uint32x4_t
foo (float32x4_t a)
{
  return vcvtnq_u32_f32 (a);
}

/* { dg-final { scan-assembler "vcvtn.u32.f32"  }  } */
