/* Windows support code to wrap differences between different
   versions of the Microsoft C libaries.
   Copyright (C) 2021 Free Software Foundation, Inc.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation; either version 3, or (at your option) any later
version.

GCC is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

Under Section 7 of GPL version 3, you are granted additional
permissions described in the GCC Runtime Library Exception, version
3.1, as published by the Free Software Foundation.

You should have received a copy of the GNU General Public License and
a copy of the GCC Runtime Library Exception along with this program;
see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see
<http://www.gnu.org/licenses/>.  */

#ifdef __MINGW32__
#include <_mingw.h>
#endif
#include <stdio.h>

/* The D runtime library defines stdin, stdout, and stderr as extern(C) symbols
   in the core.stdc.stdio module, and require initializing at start-up.  */
__attribute__((weakref ("stdin")))
static FILE *core_stdc_stdin;

__attribute__((weakref ("stdout")))
static FILE *core_stdc_stdout;

__attribute__((weakref ("stderr")))
static FILE *core_stdc_stderr;

/* Set to 1 if runtime is using libucrt.dll.  */
unsigned char msvcUsesUCRT;

void init_msvc()
{
  core_stdc_stdin = stdin;
  core_stdc_stdout = stdout;
  core_stdc_stderr = stderr;

#if __MSVCRT_VERSION__ >= 0xE00
  msvcUsedUCRT = 1;
#endif
}
