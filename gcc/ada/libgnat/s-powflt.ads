------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                    S Y S T E M . P O W T E N _ F L T                     --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--             Copyright (C) 2020, Free Software Foundation, Inc.           --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  This package provides a powers of ten table used for real conversions

package System.Powten_Flt is
   pragma Pure;

   Maxpow : constant := 38;
   --  Largest power of ten representable with Float

   Maxpow_Exact : constant := 10;
   --  Largest power of ten exactly representable with Float. It is equal to
   --  floor (M * log 2 / log 5), when M is the size of the mantissa (24).

   Powten : constant array (0 .. Maxpow) of Float :=
      (00 => 1.0E+00,
       01 => 1.0E+01,
       02 => 1.0E+02,
       03 => 1.0E+03,
       04 => 1.0E+04,
       05 => 1.0E+05,
       06 => 1.0E+06,
       07 => 1.0E+07,
       08 => 1.0E+08,
       09 => 1.0E+09,
       10 => 1.0E+10,
       11 => 1.0E+11,
       12 => 1.0E+12,
       13 => 1.0E+13,
       14 => 1.0E+14,
       15 => 1.0E+15,
       16 => 1.0E+16,
       17 => 1.0E+17,
       18 => 1.0E+18,
       19 => 1.0E+19,
       20 => 1.0E+20,
       21 => 1.0E+21,
       22 => 1.0E+22,
       23 => 1.0E+23,
       24 => 1.0E+24,
       25 => 1.0E+25,
       26 => 1.0E+26,
       27 => 1.0E+27,
       28 => 1.0E+28,
       29 => 1.0E+29,
       30 => 1.0E+30,
       31 => 1.0E+31,
       32 => 1.0E+32,
       33 => 1.0E+33,
       34 => 1.0E+34,
       35 => 1.0E+35,
       36 => 1.0E+36,
       37 => 1.0E+37,
       38 => 1.0E+38);

end System.Powten_Flt;
