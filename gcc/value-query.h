/* Support routines for value queries.
   Copyright (C) 2020-2021 Free Software Foundation, Inc.
   Contributed by Aldy Hernandez <aldyh@redhat.com> and
   Andrew Macleod <amacleod@redhat.com>.

This file is part of GCC.

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

#ifndef GCC_QUERY_H
#define GCC_QUERY_H

// The value_query class is used by optimization passes that require
// valueizing SSA names in terms of a tree value, but have no neeed
// for ranges.
//
// value_of_expr must be provided.  The default for value_on_edge and
// value_of_stmt is to call value_of_expr.
//
// This implies the valuation is global in nature.  If a pass can make
// use of more specific information, it can override the other queries.
//
// Proper usage of the correct query in passes will enable other
// valuation mechanisms to produce more precise results.

class value_query
{
public:
  value_query () { }
  // Return the singleton expression for NAME at a gimple statement,
  // or NULL if none found.
  virtual tree value_of_expr (tree name, gimple * = NULL) = 0;
  // Return the singleton expression for NAME at an edge, or NULL if
  // none found.
  virtual tree value_on_edge (edge, tree name);
  // Return the singleton expression for the LHS of a gimple
  // statement, assuming an (optional) initial value of NAME.  Returns
  // NULL if none found.
  //
  // Note that this method calculates the range the LHS would have
  // *after* the statement has executed.
  virtual tree value_of_stmt (gimple *, tree name = NULL);

private:
  DISABLE_COPY_AND_ASSIGN (value_query);
};

// The range_query class is used by optimization passes which are
// range aware.
//
// range_of_expr must be provided.  The default for range_on_edge and
// range_of_stmt is to call range_of_expr.  If a pass can make use of
// more specific information, then it can override the other queries.
//
// The default for the value_* routines is to call the equivalent
// range_* routines, check if the range is a singleton, and return it
// if so.
//
// The get_value_range method is currently provided for compatibility
// with vr-values.  It will be deprecated when possible.

class range_query : public value_query
{
public:
  range_query ();
  virtual ~range_query ();

  virtual tree value_of_expr (tree name, gimple * = NULL) OVERRIDE;
  virtual tree value_on_edge (edge, tree name) OVERRIDE;
  virtual tree value_of_stmt (gimple *, tree name = NULL) OVERRIDE;

  // These are the range equivalents of the value_* methods.  Instead
  // of returning a singleton, they calculate a range and return it in
  // R.  TRUE is returned on success or FALSE if no range was found.
  //
  // Note that range_of_expr must always return TRUE unless ranges are
  // unsupported for NAME's type (supports_type_p is false).
  virtual bool range_of_expr (irange &r, tree name, gimple * = NULL) = 0;
  virtual bool range_on_edge (irange &r, edge, tree name);
  virtual bool range_of_stmt (irange &r, gimple *, tree name = NULL);

  // DEPRECATED: This method is used from vr-values.  The plan is to
  // rewrite all uses of it to the above API.
  virtual const class value_range_equiv *get_value_range (const_tree,
							  gimple * = NULL);

protected:
  class value_range_equiv *allocate_value_range_equiv ();
  void free_value_range_equiv (class value_range_equiv *);

private:
  class equiv_allocator *equiv_alloc;
};

#endif // GCC_QUERY_H
