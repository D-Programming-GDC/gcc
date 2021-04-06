// Copyright (C) 2020-2021 Free Software Foundation, Inc.
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

// { dg-options "-std=gnu++2a" }
// { dg-do run { target c++2a } }

#include <algorithm>
#include <ranges>
#include <testsuite_hooks.h>
#include <testsuite_iterators.h>
#include <tuple>

namespace ranges = std::ranges;
namespace views = ranges::views;

void
test01()
{
  std::tuple<int, int> x[] = {{1,2},{3,4},{5,6}};
  auto v0 = x | views::elements<0>;
  VERIFY( ranges::equal(v0, (int[]){1,3,5}) );
  VERIFY( ranges::equal(v0, x | views::keys) );
  VERIFY( ranges::size(v0) == 3 );

  using R0 = decltype(v0);
  static_assert(ranges::random_access_range<R0>);
  static_assert(ranges::sized_range<R0>);

  auto v1 = x | views::reverse | views::elements<1> | views::reverse;
  VERIFY( ranges::equal(v1, (int[]){2,4,6}) );
  VERIFY( ranges::equal(v1, x | views::values) );
}

struct S
{
  friend bool
  operator==(std::input_iterator auto const& i, S)
  { return std::get<1>(*i) == 0; }
};

void
test02()
{
  // This verifies that P1994R1 (and LWG3406) is implemented.
  std::pair<std::pair<char, int>, long> x[]
    = {{{1,2},3l}, {{1,0},2l}, {{1,2},0l}};
  ranges::subrange r{ranges::begin(x), S{}};

  auto v = r | views::keys;
  VERIFY( ranges::equal(v, (std::pair<char, int>[]){{1,2},{1,0}}) );
  ranges::subrange v2{ranges::begin(v), S{}};
  VERIFY( ranges::equal(v2, (std::pair<char, int>[]){{1,2}}) );
}

struct X
{
  using Iter = __gnu_test::forward_iterator_wrapper<std::pair<int, X>>;

  friend auto operator-(Iter l, Iter r) { return l.ptr - r.ptr; }
};

void
test03()
{
  // LWG 3483
  std::pair<int, X> x[3];
  __gnu_test::test_forward_range<std::pair<int, X>> r(x);
  auto v = views::elements<1>(r);
  auto b = begin(v);
  static_assert( !ranges::random_access_range<decltype(r)> );
  static_assert( std::sized_sentinel_for<decltype(b), decltype(b)> );
  VERIFY( (next(b, 1) - b) == 1 );
  const auto v_const = v;
  auto b_const = begin(v_const);
  VERIFY( (next(b_const, 2) - b_const) == 2 );
}

int
main()
{
  test01();
  test02();
  test03();
}
