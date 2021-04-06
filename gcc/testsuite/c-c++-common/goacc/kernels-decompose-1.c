/* Test OpenACC 'kernels' construct decomposition.  */

/* { dg-additional-options "-fopt-info-omp-all" } */
/* { dg-additional-options "-fdump-tree-gimple" } */
/* { dg-additional-options "-fopenacc-kernels=decompose" }
   { dg-additional-options "-fdump-tree-omp_oacc_kernels_decompose" } */

/* See also '../../gfortran.dg/goacc/kernels-decompose-1.f95'.  */

/* It's only with Tcl 8.5 (released in 2007) that "the variable 'varName'
   passed to 'incr' may be unset, and in that case, it will be set to [...]",
   so to maintain compatibility with earlier Tcl releases, we manually
   initialize counter variables:
   { dg-line l_dummy[variable c_loop_i 0] }
   { dg-message "dummy" "" { target iN-VAl-Id } l_dummy } to avoid
   "WARNING: dg-line var l_dummy defined, but not used".  */

#define N 1024

unsigned int a[N];

int
main (void)
{
  int i;
  unsigned int sum = 1;

#pragma acc kernels copyin(a[0:N]) copy(sum)
  /* { dg-bogus "optimized: assigned OpenACC seq loop parallelism" "TODO" { xfail *-*-* } .-1 }
     TODO Is this maybe the report that belongs to the XFAILed report further down?  */
  {
    #pragma acc loop /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (i = 0; i < N; ++i)
      sum += a[i];

    sum++; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */
    a[0]++;

    #pragma acc loop independent /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC gang vector loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (i = 0; i < N; ++i)
      sum += a[i];

    if (sum > 10) /* { dg-message "note: beginning 'parloops' part in OpenACC 'kernels' region" } */
      { 
        #pragma acc loop /* { dg-line l_loop_i[incr c_loop_i] } */
	/* { dg-missed "unparallelized loop nest in OpenACC 'kernels' region: it's executed conditionally" "" { target *-*-* } l_loop_i$c_loop_i } */
	/*TODO { dg-optimized "assigned OpenACC seq loop parallelism" "TODO" { xfail *-*-* } l_loop_i$c_loop_i } */
        for (i = 0; i < N; ++i)
          sum += a[i];
      }

    #pragma acc loop auto /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (i = 0; i < N; ++i)
      sum += a[i];
  }

  return 0;
}

/* { dg-final { scan-tree-dump-times {(?n)#pragma omp target oacc_kernels map\(tofrom:sum \[len: [0-9]+\]\) map\(to:a\[0\] \[len: [0-9]+\]\) map\(firstprivate:a \[pointer assign, bias: 0\]\)$} 1 "gimple" } }

   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop private\(i\)$} 2 "gimple" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop independent private\(i\)$} 1 "gimple" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop auto private\(i\)$} 1 "gimple" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop} 4 "gimple" } } */

/* Check that the OpenACC 'kernels' got decomposed into 'data' and an enclosed
   sequence of compute constructs.
   { dg-final { scan-tree-dump-times {(?n)#pragma omp target oacc_data_kernels map\(tofrom:sum \[len: [0-9]+\]\) map\(to:a\[0\] \[len: [0-9]+\]\)$} 1 "omp_oacc_kernels_decompose" } }
   As noted above, we get three "old-style" kernel regions, one gang-single region, and one parallelized loop region.
   { dg-final { scan-tree-dump-times {(?n)#pragma omp target oacc_kernels async\(-1\) map\(force_present:sum \[len: [0-9]+\]\) map\(force_present:a\[0\] \[len: [0-9]+\]\) map\(firstprivate:a \[pointer assign, bias: 0\]\)$} 3 "omp_oacc_kernels_decompose" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma omp target oacc_parallel_kernels_parallelized async\(-1\) map\(force_present:sum \[len: [0-9]+\]\) map\(force_present:a\[0\] \[len: [0-9]+\]\) map\(firstprivate:a \[pointer assign, bias: 0\]\)$} 1 "omp_oacc_kernels_decompose" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma omp target oacc_parallel_kernels_gang_single async\(-1\) num_gangs\(1\) map\(force_present:sum \[len: [0-9]+\]\) map\(force_present:a\[0\] \[len: [0-9]+\]\) map\(firstprivate:a \[pointer assign, bias: 0\]\)$} 1 "omp_oacc_kernels_decompose" } }

   'data' plus five CCs.
   { dg-final { scan-tree-dump-times {(?n)#pragma omp target } 6 "omp_oacc_kernels_decompose" } }

   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop private\(i\)$} 2 "omp_oacc_kernels_decompose" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop independent private\(i\)$} 1 "omp_oacc_kernels_decompose" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop auto private\(i\)$} 1 "omp_oacc_kernels_decompose" } }
   { dg-final { scan-tree-dump-times {(?n)#pragma acc loop} 4 "omp_oacc_kernels_decompose" } }

   Each of the parallel regions is async, and there is a final call to
   __builtin_GOACC_wait.
   { dg-final { scan-tree-dump-times "__builtin_GOACC_wait" 1 "omp_oacc_kernels_decompose" } } */
