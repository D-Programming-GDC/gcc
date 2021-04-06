------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                                 C U D A                                  --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--          Copyright (C) 2010-2020, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT; see file COPYING3.  If not, go to --
-- http://www.gnu.org/licenses for a complete copy of the license.          --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  This package defines CUDA-specific datastructures and subprograms.
--
--  Compiling for CUDA requires compiling for two targets. One is the CPU (more
--  frequently named "host"), the other is the GPU (the "device"). Compiling
--  for the host requires compiling the whole program. Compiling for the device
--  only requires compiling packages that contain CUDA kernels.
--
--  When compiling for the device, GNAT-LLVM is used. It produces assembly
--  tailored to Nvidia's GPU (NVPTX). This NVPTX code is then assembled into
--  an object file by ptxas, an assembler provided by Nvidia. This object file
--  is then combined with its source code into a fat binary by a tool named
--  `fatbin`, also provided by Nvidia. The resulting fat binary is turned into
--  a regular object file by the host's linker and linked with the program that
--  executes on the host.
--
--  A CUDA kernel is a procedure marked with the CUDA_Global pragma or aspect.
--  CUDA_Global does not have any effect when compiling for the device. When
--  compiling for the host, the frontend stores procedures marked with
--  CUDA_Global in a hash table the key of which is the Node_Id of the package
--  body that contains the CUDA_Global procedure. This is done in sem_prag.adb.
--  Once the declarations of a package body have been analyzed, variable, type
--  and procedure declarations necessary for the initialization of the CUDA
--  runtime are appended to the package that contains the CUDA_Global
--  procedure.
--
--  These declarations are used to register the CUDA kernel with the CUDA
--  runtime when the program is launched. Registering a CUDA kernel with the
--  CUDA runtime requires multiple function calls:
--  - The first one registers the fat binary which corresponds to the package
--    with the CUDA runtime.
--  - Then, as many function calls as there are kernels in order to bind them
--    with the fat binary.
--    fat binary.
--  - The last call lets the CUDA runtime know that we are done initializing
--    CUDA.
--  Expansion of the CUDA_Global aspect is triggered in sem_ch7.adb, during
--  analysis of the package. All of this expansion is performed in the
--  Insert_CUDA_Initialization procedure defined in GNAT_CUDA.
--
--  Once a CUDA package is initialized, its kernels are ready to be used.
--  Launching CUDA kernels is done by using the CUDA_Execute pragma. When
--  compiling for the host, the CUDA_Execute pragma is expanded into a declare
--  block which performs calls to the CUDA runtime functions.
--  - The first one pushes a "launch configuration" on the "configuration
--    stack" of the CUDA runtime.
--  - The second call pops this call configuration, making it effective.
--  - The third call actually launches the kernel.
--  Light validation of the CUDA_Execute pragma is performed in sem_prag.adb
--  and expansion is performed in exp_prag.adb.

with Types; use Types;

package GNAT_CUDA is

   procedure Add_CUDA_Kernel (Pack_Id : Entity_Id; Kernel : Entity_Id);
   --  Add Kernel to the list of CUDA_Global nodes that belong to Pack_Id.
   --  Kernel is a procedure entity marked with CUDA_Global, Pack_Id is the
   --  entity of its parent package body.

   procedure Build_And_Insert_CUDA_Initialization (N : Node_Id);
   --  Builds declarations necessary for CUDA initialization and inserts them
   --  in N, the package body that contains CUDA_Global nodes. These
   --  declarations are:
   --
   --    * A symbol to hold the pointer to the CUDA fat binary
   --
   --    * A type definition for a wrapper that contains the pointer to the
   --      CUDA fat binary
   --
   --    * An object of the aforementioned type to hold the aforementioned
   --      pointer.
   --
   --    * For each CUDA_Global procedure in the package, a declaration of a C
   --      string containing the function's name.
   --
   --    * A function that takes care of calling CUDA functions that register
   --      CUDA_Global procedures with the runtime.
   --
   --    * A boolean that holds the result of the call to the aforementioned
   --      function.

end GNAT_CUDA;
