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
// { dg-do compile { target c++2a } }

#include <algorithm>
#include <ranges>
#include <string_view>

namespace ranges = std::ranges;
namespace views = std::ranges::views;

void
test01()
{
  using namespace std::literals;
  auto x = "the  quick  brown  fox"sv;
  auto v = views::split(x, std::initializer_list<char>{' ', ' '});
  v.begin(); // { dg-error "" }
}

void
test02()
{
  using namespace std::literals;
  auto x = "the  quick  brown  fox"sv;
  auto v = x | views::split(std::initializer_list<char>{' ', ' '}); // { dg-error "no match" }
  v.begin();
}

// { dg-prune-output "in requirements" }
// { dg-error "deduction failed" "" { target *-*-* } 0 }
// { dg-error "no match" "" { target *-*-* } 0 }
// { dg-error "constraint failure" "" { target *-*-* } 0 }
