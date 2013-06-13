// { dg-do compile }

// 2013-02-13  Edward Smith-Rowland <3dw4rd@verizon.net>
//
// Copyright (C) 2013 Free Software Foundation, Inc.
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the
// terms of the GNU General Public License as published by the
// Free Software Foundation; either version 3, or (at your option)
// any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this library; see the file COPYING3.  If not see
// <http://www.gnu.org/licenses/>.

// PR libstdc++/56430 - In __airy: return-statement with a value,
//				   in function returning 'void'.

#include <tr1/cmath>

int
test01()
{
  bool test __attribute__((unused)) = true;
  double x, Ai, Bi, Aip, Bip;
  x = 1.0;
  std::tr1::__detail::__airy(x, Ai, Bi, Aip, Bip);

  double Ai2 = __gnu_cxx::__airy_ai(x);
  double Bi2 = __gnu_cxx::__airy_bi(x);
}
