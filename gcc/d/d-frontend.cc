/* d-frontend.cc -- D frontend interface to the gcc back-end.
   Copyright (C) 2013-2020 Free Software Foundation, Inc.

GCC is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

GCC is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

#include "config.h"
#include "system.h"
#include "coretypes.h"

#include "dmd/aggregate.h"
#include "dmd/declaration.h"
#include "dmd/expression.h"
#include "dmd/module.h"
#include "dmd/mtype.h"
#include "dmd/scope.h"

#include "tree.h"
#include "fold-const.h"
#include "diagnostic.h"

#include "d-tree.h"

/* Implements back-end specific interfaces used by the frontend.  */

/* Determine if function FD is a builtin one that we can evaluate in CTFE.  */

BUILTIN
isBuiltin (FuncDeclaration *fd)
{
  if (fd->builtin != BUILTINunknown)
    return fd->builtin;

  maybe_set_intrinsic (fd);

  return fd->builtin;
}

/* Evaluate builtin D function FD whose argument list is ARGUMENTS.
   Return result; NULL if cannot evaluate it.  */

Expression *
eval_builtin (Loc loc, FuncDeclaration *fd, Expressions *arguments)
{
  if (fd->builtin != BUILTINyes)
    return NULL;

  tree decl = get_symbol_decl (fd);
  gcc_assert (fndecl_built_in_p (decl)
	      || DECL_INTRINSIC_CODE (decl) != INTRINSIC_NONE);

  TypeFunction *tf = (TypeFunction *) fd->type;
  Expression *e = NULL;
  input_location = make_location_t (loc);

  tree result = d_build_call (tf, decl, NULL, arguments);
  result = fold (result);

  /* Builtin should be successfully evaluated.
     Will only return NULL if we can't convert it.  */
  if (TREE_CONSTANT (result) && TREE_CODE (result) != CALL_EXPR)
    e = d_eval_constant_expression (result);

  return e;
}

/* Build and return typeinfo type for TYPE.  */

Type *
getTypeInfoType (Loc loc, Type *type, Scope *sc)
{
  if (!global.params.useTypeInfo)
    {
      /* Even when compiling without RTTI we should still be able to evaluate
	 TypeInfo at compile-time, just not at run-time.  */
      if (!sc || !(sc->flags & SCOPEctfe))
	{
	  static int warned = 0;

	  if (!warned)
	    {
	      error_at (make_location_t (loc),
			"%<object.TypeInfo%> cannot be used with %<-fno-rtti%>");
	      warned = 1;
	    }
	}
    }

  if (Type::dtypeinfo == NULL
      || (Type::dtypeinfo->storage_class & STCtemp))
    {
      /* If TypeInfo has not been declared, warn about each location once.  */
      static Loc warnloc;

      if (!loc.equals (warnloc))
	{
	  error_at (make_location_t (loc),
		    "%<object.TypeInfo%> could not be found, "
		    "but is implicitly used");
	  warnloc = loc;
	}

      return Type::terror;
    }

  gcc_assert (type->ty != Terror);
  create_typeinfo (type, sc ? sc->_module->importedFrom : NULL);
  return type->vtinfo->type;
}
