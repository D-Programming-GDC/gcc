/* d-target.h -- Data structure definitions for target-specific D behavior.
   Copyright (C) 2017-2019 Free Software Foundation, Inc.

   This program is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by the
   Free Software Foundation; either version 3, or (at your option) any
   later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; see the file COPYING3.  If not see
   <http://www.gnu.org/licenses/>.  */

#ifndef GCC_D_TARGET_H
#define GCC_D_TARGET_H

#define DEFHOOKPOD(NAME, DOC, TYPE, INIT) TYPE NAME;
#define DEFHOOK(NAME, DOC, TYPE, PARAMS, INIT) TYPE (* NAME) PARAMS;
#define DEFHOOK_UNDOC DEFHOOK
#define HOOKSTRUCT(FRAGMENT) FRAGMENT

#include "d-target.def"

/* Each target can provide their own.  */
extern struct gcc_targetdm targetdm;

/* Used by target to add predefined version identifiers.  */
extern void d_add_builtin_version (const char *);

/* Used by target to emit ModuleInfo references to minfo section.  */
extern tree emit_minfo_section (void *decl, tree minfo);

/* Used by target to register minfo section with runtime.  */
extern void register_minfo_section ();

/* Default implementation to register minfo section with runtime.  */
extern void d_register_module_default (void *module_decl, tree minfo);

#endif /* GCC_D_TARGET_H  */
