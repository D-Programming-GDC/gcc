/* { dg-do compile { target R_flag_in_section } } */
/* { dg-skip-if "non-ELF target" { *-*-darwin* powerpc*-*-aix* } } */
/* { dg-options "-Wall -O2" } */

struct dtv_slotinfo_list
{
  struct dtv_slotinfo_list *next;
};

extern struct dtv_slotinfo_list *list;

static int __attribute__ ((section ("__libc_freeres_fn")))
free_slotinfo (struct dtv_slotinfo_list **elemp)
/* { dg-warning "'.*' without 'retain' attribute and '.*' with 'retain' attribute are placed in a section with the same name" "" { target R_flag_in_section } .-1 } */
{
  if (!free_slotinfo (&(*elemp)->next))
    return 0;
  return 1;
}

__attribute__ ((used, retain, section ("__libc_freeres_fn")))
static void free_mem (void)
{
  free_slotinfo (&list);
}

/* { dg-final { scan-assembler "__libc_freeres_fn,\"ax\"" { target R_flag_in_section } } } */
/* { dg-final { scan-assembler "__libc_freeres_fn,\"axR\"" { target R_flag_in_section } } } */
