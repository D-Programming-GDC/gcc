/* PR target/98998 */
/* { dg-do compile { target fstack_protector } } */
/* { dg-options "-mpure-code -fstack-protector" } */

void *volatile p;

int
main ()
{
  int n = 0;
 lab:;
  int x[n % 1000 + 1];
  x[0] = 1;
  x[n % 1000] = 2;
  p = x;
  n++;
  if (n < 1000000)
    goto lab;
  return 0;
}
