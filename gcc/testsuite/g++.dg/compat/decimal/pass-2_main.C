/* { dg-require-effective-target dfp } */
/* { dg-require-effective-target dfprt } */

/* Test passing decimal classes by value.  */

extern void pass_2_x (void);
int fails;

int
main ()
{
  pass_2_x ();
  return 0;
}
