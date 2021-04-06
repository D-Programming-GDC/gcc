/* PR tree-optimization/96928 */
/* { dg-do compile } */
/* { dg-options "-O2 -fdump-tree-phiopt2" } */
/* { dg-final { scan-tree-dump-times " = a_\[0-9]*\\\(D\\\) >> " 5 "phiopt2" } } */
/* { dg-final { scan-tree-dump-times " = ~c_\[0-9]*\\\(D\\\);" 1 "phiopt2" } } */
/* { dg-final { scan-tree-dump-times " = ~" 1 "phiopt2" } } */
/* { dg-final { scan-tree-dump-times " = \[abc_0-9\\\(\\\)D]* \\\^ " 5 "phiopt2" } } */
/* { dg-final { scan-tree-dump-not "a < 0" "phiopt2" } } */

int
foo (int a)
{
  return a < 0 ? ~a : a;
}

int
bar (int a, int b)
{
  return a < 0 ? ~b : b;
}

unsigned
baz (int a, unsigned int b)
{
  return a < 0 ? ~b : b;
}

unsigned
qux (int a, unsigned int c)
{
  return a >= 0 ? ~c : c;
}

int
corge (int a, int b)
{
  return a >= 0 ? b : ~b;
}
