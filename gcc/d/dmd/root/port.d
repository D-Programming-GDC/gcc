/**
 * Portable routines for functions that have different implementations on different platforms.
 *
 * Copyright: Copyright (C) 1999-2021 by The D Language Foundation, All Rights Reserved
 * Authors:   Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/root/port.d, root/_port.d)
 * Documentation:  https://dlang.org/phobos/dmd_root_port.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/root/port.d
 */

module dmd.root.port;

nothrow @nogc:

extern (C++) struct Port
{
    nothrow @nogc:

    static int memicmp(scope const char* s1, scope const char* s2, size_t n) pure;

    static char* strupr(char* s) pure;

    static bool isFloat32LiteralOutOfRange(scope const(char)* s);

    static bool isFloat64LiteralOutOfRange(scope const(char)* s);

    // Little endian
    static void writelongLE(uint value, scope void* buffer) pure;

    // Little endian
    static uint readlongLE(scope const void* buffer) pure;

    // Big endian
    static void writelongBE(uint value, scope void* buffer) pure;

    // Big endian
    static uint readlongBE(scope const void* buffer) pure;

    // Little endian
    static uint readwordLE(scope const void* buffer) pure;

    // Big endian
    static uint readwordBE(scope const void* buffer) pure;

    static void valcpy(scope void *dst, ulong val, size_t size) pure
    {
        switch (size)
        {
            case 1: *cast(ubyte *)dst = cast(ubyte)val; break;
            case 2: *cast(ushort *)dst = cast(ushort)val; break;
            case 4: *cast(uint *)dst = cast(uint)val; break;
            case 8: *cast(ulong *)dst = cast(ulong)val; break;
            default: assert(0);
        }
    }
}
