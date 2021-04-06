// Copyright (C) 2021 Free Software Foundation, Inc.
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the
// terms of the GNU General Public License as published by the
// Free Software Foundation; either version 3, or (at your option)
// any later version.

// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License along
// with this library; see the file COPYING3.  If not see
// <http://www.gnu.org/licenses/>.

// { dg-options "-std=gnu++23" }
// { dg-do compile { target c++23 } }

#include <type_traits>

#ifndef __cpp_lib_is_scoped_enum
# error "Feature test macro for is_scoped_enum is missing in <type_traits>"
#elif __cpp_lib_is_scoped_enum < 202011L
# error "Feature test macro for is_scoped_enum has wrong value in <type_traits>"
#endif

#include <testsuite_tr1.h>

template<typename T>
  concept Is_scoped_enum
    = __gnu_test::test_category<std::is_scoped_enum, T>(true);

void
test01()
{
  enum class E { e1, e2 };
  static_assert( Is_scoped_enum<E> );
  enum class Ec : char { e1, e2 };
  static_assert( Is_scoped_enum<Ec> );

  // negative tests
  enum U { u1, u2 };
  static_assert( ! Is_scoped_enum<U> );
  enum F : int { f1, f2 };
  static_assert( ! Is_scoped_enum<F> );
  struct S { };
  static_assert( ! Is_scoped_enum<S> );

  static_assert( ! Is_scoped_enum<int> );
  static_assert( ! Is_scoped_enum<int[]> );
  static_assert( ! Is_scoped_enum<int[2]> );
  static_assert( ! Is_scoped_enum<int[][2]> );
  static_assert( ! Is_scoped_enum<int[2][3]> );
  static_assert( ! Is_scoped_enum<int*> );
  static_assert( ! Is_scoped_enum<int&> );
  static_assert( ! Is_scoped_enum<int*&> );
  static_assert( ! Is_scoped_enum<int()> );
  static_assert( ! Is_scoped_enum<int(*)()> );
  static_assert( ! Is_scoped_enum<int(&)()> );
}
