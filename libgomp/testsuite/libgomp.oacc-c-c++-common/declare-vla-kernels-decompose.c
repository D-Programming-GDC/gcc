/* { dg-additional-options "-fopenacc-kernels=decompose" } */

/* See also 'declare-vla-kernels-decompose-ice-1.c'.  */

#define KERNELS_DECOMPOSE_ICE_HACK
#include "declare-vla.c"
