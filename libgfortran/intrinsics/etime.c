/* Implementation of the ETIME intrinsic.
   Copyright (C) 2004 Free Software Foundation, Inc.
   Contributed by Steven G. Kargl <kargls@comcast.net>.

This file is part of the GNU Fortran 95 runtime library (libgfortran).

Libgfortran is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

Libgfortran is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with libgfor; see the file COPYING.LIB.  If not,
write to the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
Boston, MA 02111-1307, USA.  */

#include "config.h"
#include <sys/types.h>
#include "libgfortran.h"

#include <stdio.h>

#if defined (HAVE_SYS_TIME_H) && defined (HAVE_SYS_RESOURCE_H)
#include <sys/time.h>
#include <sys/resource.h>
#endif

void
prefix(etime_sub) (gfc_array_r4 *t, GFC_REAL_4 *result)
{
  GFC_REAL_4 tu, ts, tt, *tp;
  index_type dim;

#if defined(HAVE_SYS_TIME_H) && defined(HAVE_SYS_RESOURCE_H)
  struct rusage rt;

  if (getrusage(RUSAGE_SELF, &rt) == 0)
    {
      tu = (GFC_REAL_4)(rt.ru_utime.tv_sec + 1.e-6 * rt.ru_utime.tv_usec);
      ts = (GFC_REAL_4)(rt.ru_stime.tv_sec + 1.e-6 * rt.ru_stime.tv_usec);
      tt = tu + ts;
    }
  else
    {
      tu = -1.;
      ts = -1.;
      tt = -1.;
    }
#else
  tu = -1.;
  ts = -1.;
  tt = -1.;
#endif

  dim = GFC_DESCRIPTOR_RANK (t);
  if (dim != 1)
    runtime_error ("Array rank of TARRAY is not 1.");

  if (t->dim[0].stride == 0)
    t->dim[0].stride = 1;

  tp = t->data;

  *tp = tu;
  tp += t->dim[0].stride;
  *tp = ts;
  *result = tt;
}

GFC_REAL_4
prefix(etime) (gfc_array_r4 *t)
{
  GFC_REAL_4 val;
  prefix(etime_sub) (t, &val);
  return val;
}
