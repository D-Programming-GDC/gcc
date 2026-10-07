/* { dg-do compile } */
/* { dg-additional-options "-fdump-tree-gimple -w" } */

// PR middle-end/127723

#pragma omp declare simd simdlen(scaled(int, 1): 1)
void g1(int a) { }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'g1'" "" { target c } .-1 }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'void g1\\(int\\)'" "" { target c++ } .-2 }

#pragma omp declare simd simdlen(scaled(float, 2): 2)
void g2(int a) { }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'g2'" "" { target c } .-1 }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'void g2\\(int\\)'" "" { target c++ } .-2 }

#pragma omp declare simd simdlen(scaled(_Complex double): 4)
void g3(int a) { }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'g3'" "" { target c } .-1 }
// { dg-message "sorry, unimplemented: 'scaled' modifier specified in 'simdlen' clause on 'declare simd' directive for 'void g3\\(int\\)'" "" { target c++ } .-2 }

/* { dg-final { scan-tree-dump "__attribute__\\(\\(omp declare simd \\(simdlen\\(scaled\\(int,1\\):1\\)\\)\\)\\)" "gimple" } } */
/* { dg-final { scan-tree-dump "__attribute__\\(\\(omp declare simd \\(simdlen\\(scaled\\(float,2\\):2\\)\\)\\)\\)" "gimple" } } */
/* { dg-final { scan-tree-dump "__attribute__\\(\\(omp declare simd \\(simdlen\\(scaled\\(complex double\\):4\\)\\)\\)\\)" "gimple" } } */
