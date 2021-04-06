/* Test OpenACC 'kernels' construct decomposition.  */

/* { dg-additional-options "-fopt-info-omp-all" } */
/* { dg-additional-options "-fopenacc-kernels=decompose" } */

/* It's only with Tcl 8.5 (released in 2007) that "the variable 'varName'
   passed to 'incr' may be unset, and in that case, it will be set to [...]",
   so to maintain compatibility with earlier Tcl releases, we manually
   initialize counter variables:
   { dg-line l_dummy[variable c_loop_i 0] }
   { dg-message "dummy" "" { target iN-VAl-Id } l_dummy } to avoid
   "WARNING: dg-line var l_dummy defined, but not used".  */

#undef NDEBUG
#include <assert.h>

int main()
{
  int a = 0;
  /*TODO Without making 'a' addressable, for GCN offloading we will not see the expected value copied out.  (But it does work for nvptx offloading, strange...)  */
  (volatile int *) &a;
#define N 123
  int b[N] = { 0 };

#pragma acc kernels
  {
    int c = 234; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */

    /*TODO Hopefully, this is the same issue as '../../../gcc/testsuite/c-c++-common/goacc/kernels-decompose-ice-1.c'.  */
    (volatile int *) &c;

#pragma acc loop independent gang /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC gang loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0; i < N; ++i)
      b[i] = c;

    a = c; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */
  }

  for (int i = 0; i < N; ++i)
    assert (b[i] == 234);
  assert (a == 234);

  return 0;
}
