/* { dg-do run { target { power10_hw } } } */
/* { dg-do link { target { ! power10_hw } } } */
/* { dg-require-effective-target power10_ok } */
/* { dg-options "-mdejagnu-cpu=power10" } */

#include <altivec.h>

extern void abort (void);

/* Vector string isolate right-justified on array of unsigned short.  */
vector unsigned short
sirj (vector unsigned short arg)
{
  return vec_strir (arg);
}

int main (int argc, short *argv [])
{
  vector unsigned short input1 =
    { 0x1, 0x3, 0x5, 0x7, 0x9, 0xb, 0xd, 0xf };
  vector unsigned short expected1 =
    { 0x1, 0x3, 0x5, 0x7, 0x9, 0xb, 0xd, 0xf };
  vector unsigned short input2 =
    { 0x1, 0x0, 0x5, 0x7, 0x9, 0xb, 0xd, 0xf };
  vector unsigned short expected2 =
    { 0x0, 0x0, 0x5, 0x7, 0x9, 0xb, 0xd, 0xf };
  vector unsigned short input3 =
    { 0x1, 0x0, 0x5, 0x7, 0x9, 0xb, 0xd, 0x0 };
  vector unsigned short expected3 =
    { 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0 };
  vector unsigned short input4 =
    { 0x1, 0x3, 0x5, 0x7, 0x9, 0xb, 0xd, 0x0 };
  vector unsigned short expected4 =
    { 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0 };

  if (!vec_all_eq (sirj (input1), expected1))
    abort ();
  if (!vec_all_eq (sirj (input2), expected2))
    abort ();
  if (!vec_all_eq (sirj (input3), expected3))
    abort ();
  if (!vec_all_eq (sirj (input4), expected4))
    abort ();

}
