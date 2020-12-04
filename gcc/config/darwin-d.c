/* Darwin support needed only by D front-end.
   Copyright (C) 2020-2021 Free Software Foundation, Inc.

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
#include "tm_d.h"
#include "d/d-target.h"
#include "d/d-target-def.h"
#include "diagnostic.h"

/* Implement TARGET_D_OS_VERSIONS for Darwin targets.  */

static void
darwin_d_os_builtins (void)
{
  d_add_builtin_version ("Posix");
  d_add_builtin_version ("OSX");
  d_add_builtin_version ("darwin");
}

/* Handle a call to `__traits(getTargetInfo, "objectFormat")'.  */

static tree
darwin_d_handle_target_object_format (void)
{
  const char *objfmt = "macho";

  return build_string_literal (strlen (objfmt) + 1, objfmt);
}

/* Given an OS X version VERSION_STR, return it as a six digit integer.  */

static unsigned long
parse_version (const char *version_str)
{
  const size_t version_len = strlen (version_str);
  if (version_len < 1)
    return 0;

  /* Version string must consist of digits and periods only.  */
  if (strspn (version_str, "0123456789.") != version_len)
    return 0;

  if (!ISDIGIT (version_str[0]) || !ISDIGIT (version_str[version_len - 1]))
    return 0;

  char *endptr;
  unsigned long major = strtoul (version_str, &endptr, 10);
  version_str = endptr + ((*endptr == '.') ? 1 : 0);

  /* Version string must not contain adjacent periods.  */
  if (*version_str == '.')
    return 0;

  unsigned long minor = strtoul (version_str, &endptr, 10);
  version_str = endptr + ((*endptr == '.') ? 1 : 0);

  unsigned long tiny = strtoul (version_str, &endptr, 10);

  /* Version string must contain no more than three tokens.  */
  if (*endptr != '\0')
    return 0;

  return (major * 10000) + (minor * 100) + tiny;
}

/* Handle a call to `__traits(getTargetInfo, "osxVersionMin")'.  */

static tree
darwin_d_handle_target_version_min (void)
{
  const unsigned long version = parse_version (darwin_macosx_version_min);

  if (version == 0)
    {
      error ("unknown value %qs of %<-mmacosx-version-min%>",
	     darwin_macosx_version_min);
    }

  return build_int_cst_type (integer_type_node, version);
}

/* Implement TARGET_D_REGISTER_OS_TARGET_INFO for Darwin targets.  */

static void
darwin_d_register_target_info (void)
{
  const struct d_target_info_spec handlers[] = {
    { "objectFormat", darwin_d_handle_target_object_format },
    { "osxVersionMin", darwin_d_handle_target_version_min },
    { NULL, NULL },
  };

  d_add_target_info_handlers (handlers);
}

#undef TARGET_D_OS_VERSIONS
#define TARGET_D_OS_VERSIONS darwin_d_os_builtins

#undef TARGET_D_REGISTER_OS_TARGET_INFO
#define TARGET_D_REGISTER_OS_TARGET_INFO darwin_d_register_target_info

/* Define TARGET_D_MINFO_SECTION for Darwin targets.  */

#undef TARGET_D_MINFO_SECTION
#define TARGET_D_MINFO_SECTION "__DATA,__minfodata"

#undef TARGET_D_MINFO_START_NAME
#define TARGET_D_MINFO_START_NAME "*section$start$__DATA$__minfodata"

#undef TARGET_D_MINFO_END_NAME
#define TARGET_D_MINFO_END_NAME "*section$end$__DATA$__minfodata"

struct gcc_targetdm targetdm = TARGETDM_INITIALIZER;
