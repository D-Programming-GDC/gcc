/* { dg-do run } */
/* { dg-skip-if "not implemented" { ! { i?86*-*-* x86_64*-*-* sparc*-*-* aarch64*-*-* arm*-*-* nvptx*-*-* } } } */
/* { dg-options "-O2 -fzero-call-used-regs=all" } */

#include "zero-scratch-regs-1.c"
