// -*- C++ -*-

// Copyright (C) 2005, 2006 Free Software Foundation, Inc.
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software
// Foundation; either version 2, or (at your option) any later
// version.

// This library is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this library; see the file COPYING.  If not, write to
// the Free Software Foundation, 59 Temple Place - Suite 330, Boston,
// MA 02111-1307, USA.

// As a special exception, you may use this file as part of a free
// software library without restriction.  Specifically, if other files
// instantiate templates or use macros or inline functions from this
// file, or you compile this file and link it with other files to
// produce an executable, this file does not by itself cause the
// resulting executable to be covered by the GNU General Public
// License.  This exception does not however invalidate any other
// reasons why the executable file might be covered by the GNU General
// Public License.

// Copyright (C) 2004 Ami Tavory and Vladimir Dreizin, IBM-HRL.

// Permission to use, copy, modify, sell, and distribute this software
// is hereby granted without fee, provided that the above copyright
// notice appears in all copies, and that both that copyright notice
// and this permission notice appear in supporting documentation. None
// of the above authors, nor IBM Haifa Research Laboratories, make any
// representation about the suitability of this software for any
// purpose. It is provided "as is" without express or implied
// warranty.

/**
 * @file find_fn_imps.hpp
 * Contains an implementation class for splay_tree_.
 */

PB_DS_CLASS_T_DEC
inline typename PB_DS_CLASS_C_DEC::point_iterator
PB_DS_CLASS_C_DEC::
find(const_key_reference r_key)
{
  node_pointer p_found = find_imp(r_key);

  if (p_found != PB_DS_BASE_C_DEC::m_p_head)
    splay(p_found);

  return (point_iterator(p_found));
}

PB_DS_CLASS_T_DEC
inline typename PB_DS_CLASS_C_DEC::const_point_iterator
PB_DS_CLASS_C_DEC::
find(const_key_reference r_key) const
{
  const node_pointer p_found = find_imp(r_key);

  if (p_found != PB_DS_BASE_C_DEC::m_p_head)
    const_cast<PB_DS_CLASS_C_DEC* >(this)->splay(p_found);

  return (point_iterator(p_found));
}

PB_DS_CLASS_T_DEC
inline typename PB_DS_CLASS_C_DEC::node_pointer
PB_DS_CLASS_C_DEC::
find_imp(const_key_reference r_key)
{
  PB_DS_DBG_ONLY(PB_DS_BASE_C_DEC::structure_only_assert_valid();)

    node_pointer p_nd = PB_DS_BASE_C_DEC::m_p_head->m_p_parent;

  while (p_nd != NULL)
    if (!Cmp_Fn::operator()(PB_DS_V2F(p_nd->m_value), r_key))
      {
	if (!Cmp_Fn::operator()(r_key, PB_DS_V2F(p_nd->m_value)))
	  return (p_nd);

	p_nd = p_nd->m_p_left;
      }
    else
      p_nd = p_nd->m_p_right;

  return PB_DS_BASE_C_DEC::m_p_head;
}

PB_DS_CLASS_T_DEC
inline const typename PB_DS_CLASS_C_DEC::node_pointer
PB_DS_CLASS_C_DEC::
find_imp(const_key_reference r_key) const
{
  PB_DS_DBG_ONLY(assert_valid();)

    node_pointer p_nd = PB_DS_BASE_C_DEC::m_p_head->m_p_parent;

  while (p_nd != NULL)
    if (!Cmp_Fn::operator()(PB_DS_V2F(p_nd->m_value), r_key))
      {
	if (!Cmp_Fn::operator()(r_key, PB_DS_V2F(p_nd->m_value)))
	  return (p_nd);

	p_nd = p_nd->m_p_left;
      }
    else
      p_nd = p_nd->m_p_right;

  return PB_DS_BASE_C_DEC::m_p_head;
}
