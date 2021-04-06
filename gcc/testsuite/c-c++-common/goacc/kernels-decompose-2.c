/* Test OpenACC 'kernels' construct decomposition.  */

/* { dg-additional-options "-fopt-info-omp-all" } */
/* { dg-additional-options "-fopenacc-kernels=decompose" }
/* { dg-additional-options "-O2" } for 'parloops'.  */

/* See also '../../gfortran.dg/goacc/kernels-decompose-2.f95'.  */

/* It's only with Tcl 8.5 (released in 2007) that "the variable 'varName'
   passed to 'incr' may be unset, and in that case, it will be set to [...]",
   so to maintain compatibility with earlier Tcl releases, we manually
   initialize counter variables:
   { dg-line l_dummy[variable c_loop_i 0 c_loop_j 0 c_loop_k 0 c_part 0] }
   { dg-message "dummy" "" { target iN-VAl-Id } l_dummy } to avoid
   "WARNING: dg-line var l_dummy defined, but not used".  */

#pragma acc routine gang
extern int
f_g (int);

#pragma acc routine worker
extern int
f_w (int);

#pragma acc routine vector
extern int
f_v (int);

#pragma acc routine seq
extern int
f_s (int);

int
main ()
{
  int x, y, z;
#define N 10
  int a[N], b[N], c[N];

#pragma acc kernels
  {
    x = 0; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */
    y = x < 10;
    z = x++;
    ;
  }

  { /*TODO Instead of using 'for (int i = 0; [...])', move 'int i' outside, to work around for ICE detailed in 'kernels-decompose-ice-1.c'.  */
    int i;
#pragma acc kernels /* { dg-optimized "assigned OpenACC gang loop parallelism" } */
  for (i = 0; i < N; i++) /* { dg-message "note: beginning 'parloops' part in OpenACC 'kernels' region" } */
    a[i] = 0;
  }

#pragma acc kernels loop /* { dg-line l_loop_i[incr c_loop_i] } */
  /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
  /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
  for (int i = 0; i < N; i++)
    b[i] = a[N - i - 1];

#pragma acc kernels
  {
#pragma acc loop /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0; i < N; i++)
      b[i] = a[N - i - 1];

#pragma acc loop /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0; i < N; i++)
      c[i] = a[i] * b[i];

    a[z] = 0; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */

#pragma acc loop /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: forwarded loop nest in OpenACC 'kernels' region to 'parloops' for analysis" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0; i < N; i++)
      c[i] += a[i];

#pragma acc loop seq /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0 + 1; i < N; i++)
      c[i] += c[i - 1];
  }

#pragma acc kernels
  /*TODO What does this mean?
    TODO { dg-optimized "assigned OpenACC worker vector loop parallelism" "" { target *-*-* } .-2 } */
  {
#pragma acc loop independent /* { dg-line l_loop_i[incr c_loop_i] } */
    /* { dg-optimized "assigned OpenACC gang loop parallelism" "" { target *-*-* } l_loop_i$c_loop_i } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_i$c_loop_i } */
    for (int i = 0; i < N; ++i)
#pragma acc loop independent /* { dg-line l_loop_j[incr c_loop_j] } */
      /* { dg-optimized "assigned OpenACC worker loop parallelism" "" { target *-*-* } l_loop_j$c_loop_j } */
      for (int j = 0; j < N; ++j)
#pragma acc loop independent /* { dg-line l_loop_k[incr c_loop_k] } */
	/* { dg-warning "insufficient partitioning available to parallelize loop" "" { target *-*-* } l_loop_k$c_loop_k } */
	/* { dg-optimized "assigned OpenACC seq loop parallelism" "" { target *-*-* } l_loop_k$c_loop_k } */
	for (int k = 0; k < N; ++k)
	  a[(i + j + k) % N]
	    = b[j]
	    + f_v (c[k]); /* { dg-optimized "assigned OpenACC vector loop parallelism" } */

    /*TODO Should the following turn into "gang-single" instead of "parloops"?
      TODO The problem is that the first STMT is 'if (y <= 4) goto <D.2547>; else goto <D.2548>;', thus "parloops".  */
    if (y < 5) /* { dg-message "note: beginning 'parloops' part in OpenACC 'kernels' region" } */
#pragma acc loop independent /* { dg-line l_loop_j[incr c_loop_j] } */
      /* { dg-missed "unparallelized loop nest in OpenACC 'kernels' region: it's executed conditionally" "" { target *-*-* } l_loop_j$c_loop_j } */
      for (int j = 0; j < N; ++j)
	b[j] = f_w (c[j]);
  }

#pragma acc kernels
  {
    y = f_g (a[5]); /* { dg-line l_part[incr c_part] } */
    /*TODO If such a construct is placed in its own part (like it is, here), can't this actually use gang paralelism, instead of "gang-single"?
      { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" "" { target *-*-* } l_part$c_part } */
    /* { dg-optimized "assigned OpenACC gang worker vector loop parallelism" "" { target *-*-* } l_part$c_part } */

#pragma acc loop independent /* { dg-line l_loop_j[incr c_loop_j] } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_j$c_loop_j } */
    /* { dg-optimized "assigned OpenACC gang loop parallelism" "" { target *-*-* } l_loop_j$c_loop_j } */
    for (int j = 0; j < N; ++j)
      b[j] = y + f_w (c[j]); /* { dg-optimized "assigned OpenACC worker vector loop parallelism" } */
  }

#pragma acc kernels
  {
    y = 3; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */

#pragma acc loop independent /* { dg-line l_loop_j[incr c_loop_j] } */
    /* { dg-message "note: parallelized loop nest in OpenACC 'kernels' region" "" { target *-*-* } l_loop_j$c_loop_j } */
    /* { dg-optimized "assigned OpenACC gang worker loop parallelism" "" { target *-*-* } l_loop_j$c_loop_j } */
    for (int j = 0; j < N; ++j)
      b[j] = y + f_v (c[j]); /* { dg-optimized "assigned OpenACC vector loop parallelism" } */

    z = 2; /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */
  }

#pragma acc kernels /* { dg-message "note: beginning 'gang-single' part in OpenACC 'kernels' region" } */
  ;

  return 0;
}
