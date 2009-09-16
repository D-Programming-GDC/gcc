// -*- C++ -*-

// Copyright (C) 2007, 2008, 2009 Free Software Foundation, Inc.
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software
// Foundation; either version 3, or (at your option) any later
// version.

// This library is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.

// Under Section 7 of GPL version 3, you are granted additional
// permissions described in the GCC Runtime Library Exception, version
// 3.1, as published by the Free Software Foundation.

// You should have received a copy of the GNU General Public License and
// a copy of the GCC Runtime Library Exception along with this program;
// see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see
// <http://www.gnu.org/licenses/>.

/** @file parallel/iterator.h
 * @brief Helper iterator classes for the std::transform() functions.
 *  This file is a GNU parallel extension to the Standard C++ Library.
 */

// Written by Johannes Singler.

#ifndef _GLIBCXX_PARALLEL_ITERATOR_H
#define _GLIBCXX_PARALLEL_ITERATOR_H 1

#include <parallel/basic_iterator.h>
#include <bits/stl_pair.h>

namespace __gnu_parallel
{
  /** @brief A pair of iterators. The usual iterator operations are
   *  applied to both child iterators.
   */
  template<typename _Iterator1, typename _Iterator2, typename _IteratorCategory>
    class _IteratorPair : public std::pair<_Iterator1, _Iterator2>
    {
    private:
      typedef _IteratorPair<_Iterator1, _Iterator2, _IteratorCategory> _Self;
      typedef std::pair<_Iterator1, _Iterator2> _Base;

    public:
      typedef _IteratorCategory iterator_category;
      typedef void value_type;

      typedef std::iterator_traits<_Iterator1> _TraitsType;
      typedef typename _TraitsType::difference_type difference_type;
      typedef _Self* pointer;
      typedef _Self& reference;

      _IteratorPair() { }

      _IteratorPair(const _Iterator1& __first, const _Iterator2& __second) 
      : _Base(__first, __second) { }

      // Pre-increment operator.
      _Self&
      operator++()
      {
	++_Base::first;
	++_Base::second;
	return *this;
      }

      // Post-increment operator.
      const _Self
      operator++(int)
      { return _Self(_Base::first++, _Base::second++); }

      // Pre-decrement operator.
      _Self&
      operator--()
      {
	--_Base::first;
	--_Base::second;
	return *this;
      }

      // Post-decrement operator.
      const _Self
      operator--(int)
      { return _Self(_Base::first--, _Base::second--); }

      // Type conversion.
      operator _Iterator2() const
      { return _Base::second; }

      _Self&
      operator=(const _Self& __other)
      {
	_Base::first = __other.first;
	_Base::second = __other.second;
	return *this;
      }

      _Self
      operator+(difference_type __delta) const
      { return _Self(_Base::first + __delta, _Base::second + __delta); }

      difference_type
      operator-(const _Self& __other) const
      { return _Base::first - __other.first; }
  };


  /** @brief A triple of iterators. The usual iterator operations are
      applied to all three child iterators.
   */
  template<typename _Iterator1, typename _Iterator2, typename _Iterator3,
	   typename _IteratorCategory>
    class _IteratorTriple
    {
    private:
      typedef _IteratorTriple<_Iterator1, _Iterator2, _Iterator3,
			      _IteratorCategory> _Self;

    public:
      typedef _IteratorCategory iterator_category;
      typedef void value_type;
      typedef typename std::iterator_traits<_Iterator1>::difference_type
                                                            difference_type;
      typedef _Self* pointer;
      typedef _Self& reference;

      _Iterator1 __first;
      _Iterator2 __second;
      _Iterator3 __third;

      _IteratorTriple() { }

      _IteratorTriple(const _Iterator1& _first, const _Iterator2& _second,
		      const _Iterator3& _third)
      {
	__first = _first;
	__second = _second;
	__third = _third;
      }

      // Pre-increment operator.
      _Self&
      operator++()
      {
	++__first;
	++__second;
	++__third;
	return *this;
      }

      // Post-increment operator.
      const _Self
      operator++(int)
      { return _Self(__first++, __second++, __third++); }

      // Pre-decrement operator.
      _Self&
      operator--()
      {
	--__first;
	--__second;
	--__third;
	return *this;
      }

      // Post-decrement operator.
      const _Self
      operator--(int)
      { return _Self(__first--, __second--, __third--); }

      // Type conversion.
      operator _Iterator3() const
      { return __third; }

      _Self&
      operator=(const _Self& __other)
      {
	__first = __other.__first;
	__second = __other.__second;
	__third = __other.__third;
	return *this;
      }

      _Self
      operator+(difference_type __delta) const
      { return _Self(__first + __delta, __second + __delta, __third + __delta); }

      difference_type
      operator-(const _Self& __other) const
      { return __first - __other.__first; }
  };
}

#endif /* _GLIBCXX_PARALLEL_ITERATOR_H */
