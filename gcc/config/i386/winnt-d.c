/* Windows support needed only by D front-end.
   Copyright (C) 2017 Free Software Foundation, Inc.

GCC is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation; either version 3, or (at your option) any later
version.

GCC is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

#include "config.h"
#include "system.h"
#include "coretypes.h"
#include "target.h"
#include "d/d-target.h"
#include "d/d-target-def.h"
#include "tm_p.h"

/* Implement TARGET_D_OS_VERSIONS for Windows targets.  */

static void
winnt_d_os_builtins (void)
{
  d_add_builtin_version ("Windows");

#define builtin_version(TXT) d_add_builtin_version (TXT)

#ifdef EXTRA_TARGET_D_OS_VERSIONS
  EXTRA_TARGET_D_OS_VERSIONS ();
#endif
}

/* Implement TARGET_D_CRITSEC_SIZE for Windows targets.  */

static unsigned
winnt_d_critsec_size (void)
{
  /* This is the sizeof CRITICAL_SECTION.  */
  if (TYPE_PRECISION (long_integer_type_node) == 64
      && POINTER_SIZE == 64
      && TYPE_PRECISION (integer_type_node) == 32)
    return 40;
  else
    return 24;
}

/* Implement TARGET_D_REGISTER_MODULE for Windows targets.  */

void
winnt_d_register_module (void *module_decl, tree minfo)
{
  emit_minfo_section (module_decl, minfo);
  // There is no _d_dso_registry for windows targets
}

/* Implement TARGET_D_SYSTEM_LINKAGE for Windows targets.  */

LINKAGE
winnt_d_system_linkage ()
{
  if (DEFAULT_ABI == MS_ABI)
    return LINKAGE_WINDOWS;
  else
    return LINKAGE_C;
}

#undef TARGET_D_OS_VERSIONS
#define TARGET_D_OS_VERSIONS winnt_d_os_builtins

#undef TARGET_D_CRITSEC_SIZE
#define TARGET_D_CRITSEC_SIZE winnt_d_critsec_size

#undef TARGET_D_REGISTER_MODULE
#define TARGET_D_REGISTER_MODULE winnt_d_register_module

#undef TARGET_D_SYSTEM_LINKAGE
#define TARGET_D_SYSTEM_LINKAGE winnt_d_system_linkage

struct gcc_targetdm targetdm = TARGETDM_INITIALIZER;
