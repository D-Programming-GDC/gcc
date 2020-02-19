/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/root/array.d, root/_array.d)
 * Documentation:  https://dlang.org/phobos/dmd_root_array.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/root/array.d
 */

module dmd.root.array;

import core.stdc.string;

import dmd.root.rmem;
import dmd.root.string;

debug
{
    debug = stomp; // flush out dangling pointer problems by stomping on unused memory
}

extern (C++) struct Array(T)
{
    size_t length;

private:
    T[] data;
    enum SMALLARRAYCAP = 1;
    T[SMALLARRAYCAP] smallarray; // inline storage for small arrays

public:
    /*******************
     * Params:
     *  dim = initial length of array
     */
    this(size_t dim) pure nothrow
    {
        reserve(dim);
        this.length = dim;
    }

    @disable this(this);

    ~this() pure nothrow
    {
        debug (stomp) memset(data.ptr, 0xFF, data.length);
        if (data.ptr != &smallarray[0])
            mem.xfree(data.ptr);
    }
    ///returns elements comma separated in []
    extern(D) const(char)[] toString() const
    {
        static const(char)[] toStringImpl(alias toStringFunc, Array)(Array* a, bool quoted = false)
        {
            const(char)[][] buf = (cast(const(char)[]*)mem.xcalloc((char[]).sizeof, a.length))[0 .. a.length];
            size_t len = 2; // [ and ]
            const seplen = quoted ? 3 : 1; // ',' or null terminator and optionally '"'
            if (a.length == 0)
                len += 1; // null terminator
            else
            {
                foreach (u; 0 .. a.length)
                {
                    buf[u] = toStringFunc(a.data[u]);
                    len += buf[u].length + seplen;
                }
            }
            char[] str = (cast(char*)mem.xmalloc_noscan(len))[0..len];

            str[0] = '[';
            char* p = str.ptr + 1;
            foreach (u; 0 .. a.length)
            {
                if (u)
                    *p++ = ',';
                if (quoted)
                    *p++ = '"';
                memcpy(p, buf[u].ptr, buf[u].length);
                p += buf[u].length;
                if (quoted)
                    *p++ = '"';
            }
            *p++ = ']';
            *p = 0;
            assert(p - str.ptr == str.length - 1); // null terminator
            mem.xfree(buf.ptr);
            return str[0 .. $-1];
        }

        static if (is(typeof(T.init.toString())))
        {
            return toStringImpl!(a => a.toString)(&this);
        }
        else static if (is(typeof(T.init.toDString())))
        {
            return toStringImpl!(a => a.toDString)(&this, true);
        }
        else
        {
            assert(0);
        }
    }
    ///ditto
    const(char)* toChars() const
    {
        return toString.ptr;
    }

    ref Array push(T ptr) return pure nothrow
    {
        reserve(1);
        data[length++] = ptr;
        return this;
    }

    extern (D) ref Array pushSlice(T[] a) return pure nothrow
    {
        const oldLength = length;
        setDim(oldLength + a.length);
        memcpy(data.ptr + oldLength, a.ptr, a.length * T.sizeof);
        return this;
    }

    ref Array append(typeof(this)* a) return pure nothrow
    {
        insert(length, a);
        return this;
    }

    void reserve(size_t nentries) pure nothrow
    {
        //printf("Array::reserve: length = %d, data.length = %d, nentries = %d\n", (int)length, (int)data.length, (int)nentries);
        if (data.length - length < nentries)
        {
            if (data.length == 0)
            {
                // Not properly initialized, someone memset it to zero
                if (nentries <= SMALLARRAYCAP)
                {
                    data = SMALLARRAYCAP ? smallarray[] : null;
                }
                else
                {
                    auto p = cast(T*)mem.xmalloc(nentries * T.sizeof);
                    data = p[0 .. nentries];
                }
            }
            else if (data.length == SMALLARRAYCAP)
            {
                const allocdim = length + nentries;
                auto p = cast(T*)mem.xmalloc(allocdim * T.sizeof);
                memcpy(p, smallarray.ptr, length * T.sizeof);
                data = p[0 .. allocdim];
            }
            else
            {
                /* Increase size by 1.5x to avoid excessive memory fragmentation
                 */
                auto increment = length / 2;
                if (nentries > increment)       // if 1.5 is not enough
                    increment = nentries;
                const allocdim = length + increment;
                debug (stomp)
                {
                    // always move using allocate-copy-stomp-free
                    auto p = cast(T*)mem.xmalloc(allocdim * T.sizeof);
                    memcpy(p, data.ptr, length * T.sizeof);
                    memset(data.ptr, 0xFF, data.length * T.sizeof);
                    mem.xfree(data.ptr);
                }
                else
                    auto p = cast(T*)mem.xrealloc(data.ptr, allocdim * T.sizeof);
                data = p[0 .. allocdim];
            }

            debug (stomp)
            {
                if (length < data.length)
                    memset(data.ptr + length, 0xFF, (data.length - length) * T.sizeof);
            }
            else
            {
                if (mem.isGCEnabled)
                    if (length < data.length)
                        memset(data.ptr + length, 0xFF, (data.length - length) * T.sizeof);
            }
        }
    }

    void remove(size_t i) pure nothrow @nogc
    {
        if (length - i - 1)
            memmove(data.ptr + i, data.ptr + i + 1, (length - i - 1) * T.sizeof);
        length--;
        debug (stomp) memset(data.ptr + length, 0xFF, T.sizeof);
    }

    void insert(size_t index, typeof(this)* a) pure nothrow
    {
        if (a)
        {
            size_t d = a.length;
            reserve(d);
            if (length != index)
                memmove(data.ptr + index + d, data.ptr + index, (length - index) * T.sizeof);
            memcpy(data.ptr + index, a.data.ptr, d * T.sizeof);
            length += d;
        }
    }

    void insert(size_t index, T ptr) pure nothrow
    {
        reserve(1);
        memmove(data.ptr + index + 1, data.ptr + index, (length - index) * T.sizeof);
        data[index] = ptr;
        length++;
    }

    void setDim(size_t newdim) pure nothrow
    {
        if (length < newdim)
        {
            reserve(newdim - length);
        }
        length = newdim;
    }

    size_t find(T ptr) const nothrow pure
    {
        foreach (i; 0 .. length)
            if (data[i] is ptr)
                return i;
        return size_t.max;
    }

    bool contains(T ptr) const nothrow pure
    {
        return find(ptr) != size_t.max;
    }

    ref inout(T) opIndex(size_t i) inout nothrow pure
    {
        return data[i];
    }

    inout(T)* tdata() inout pure nothrow @nogc @trusted
    {
        return data.ptr;
    }

    Array!T* copy() const pure nothrow
    {
        auto a = new Array!T();
        a.setDim(length);
        memcpy(a.data.ptr, data.ptr, length * T.sizeof);
        return a;
    }

    void shift(T ptr) pure nothrow
    {
        reserve(1);
        memmove(data.ptr + 1, data.ptr, length * T.sizeof);
        data[0] = ptr;
        length++;
    }

    void zero() nothrow pure @nogc
    {
        data[0 .. length] = T.init;
    }

    T pop() nothrow pure @nogc
    {
        debug (stomp)
        {
            assert(length);
            auto result = data[length - 1];
            remove(length - 1);
            return result;
        }
        else
            return data[--length];
    }

    extern (D) inout(T)[] opSlice() inout nothrow pure @nogc
    {
        return data[0 .. length];
    }

    extern (D) inout(T)[] opSlice(size_t a, size_t b) inout nothrow pure @nogc
    {
        assert(a <= b && b <= length);
        return data[a .. b];
    }

    alias opDollar = length;
    alias dim = length;
}

unittest
{
    // Test for objects implementing toString()
    static struct S
    {
        int s = -1;
        string toString() const
        {
            return "S";
        }
    }
    auto array = Array!S(4);
    assert(array.toString() == "[S,S,S,S]");
    array.setDim(0);
    assert(array.toString() == "[]");

    // Test for toDString()
    auto strarray = Array!(const(char)*)(2);
    strarray[0] = "hello";
    strarray[1] = "world";
    auto str = strarray.toString();
    assert(str == `["hello","world"]`);
    // Test presence of null terminator.
    assert(str.ptr[str.length] == '\0');
}

unittest
{
    auto array = Array!double(4);
    array.shift(10);
    array.push(20);
    array[2] = 15;
    assert(array[0] == 10);
    assert(array.find(10) == 0);
    assert(array.find(20) == 5);
    assert(!array.contains(99));
    array.remove(1);
    assert(array.length == 5);
    assert(array[1] == 15);
    assert(array.pop() == 20);
    assert(array.length == 4);
    array.insert(1, 30);
    assert(array[1] == 30);
    assert(array[2] == 15);
}

unittest
{
    auto arrayA = Array!int(0);
    int[3] buf = [10, 15, 20];
    arrayA.pushSlice(buf);
    assert(arrayA[] == buf[]);
    auto arrayPtr = arrayA.copy();
    assert(arrayPtr);
    assert((*arrayPtr)[] == arrayA[]);
    assert(arrayPtr.tdata != arrayA.tdata);

    arrayPtr.setDim(0);
    int[2] buf2 = [100, 200];
    arrayPtr.pushSlice(buf2);

    arrayA.append(arrayPtr);
    assert(arrayA[3..$] == buf2[]);
    arrayA.insert(0, arrayPtr);
    assert(arrayA[] == [100, 200, 10, 15, 20, 100, 200]);

    arrayA.zero();
    foreach(e; arrayA)
        assert(e == 0);
}

/**
 * Exposes the given root Array as a standard D array.
 * Params:
 *  array = the array to expose.
 * Returns:
 *  The given array exposed to a standard D array.
 */
@property inout(T)[] peekSlice(T)(inout(Array!T)* array) pure nothrow @nogc
{
    return array ? (*array)[] : null;
}

/**
 * Splits the array at $(D index) and expands it to make room for $(D length)
 * elements by shifting everything past $(D index) to the right.
 * Params:
 *  array = the array to split.
 *  index = the index to split the array from.
 *  length = the number of elements to make room for starting at $(D index).
 */
void split(T)(ref Array!T array, size_t index, size_t length) pure nothrow
{
    if (length > 0)
    {
        auto previousDim = array.length;
        array.setDim(array.length + length);
        for (size_t i = previousDim; i > index;)
        {
            i--;
            array[i + length] = array[i];
        }
    }
}
unittest
{
    auto array = Array!int();
    array.split(0, 0);
    assert([] == array[]);
    array.push(1).push(3);
    array.split(1, 1);
    array[1] = 2;
    assert([1, 2, 3] == array[]);
    array.split(2, 3);
    array[2] = 8;
    array[3] = 20;
    array[4] = 4;
    assert([1, 2, 8, 20, 4, 3] == array[]);
    array.split(0, 0);
    assert([1, 2, 8, 20, 4, 3] == array[]);
    array.split(0, 1);
    array[0] = 123;
    assert([123, 1, 2, 8, 20, 4, 3] == array[]);
    array.split(0, 3);
    array[0] = 123;
    array[1] = 421;
    array[2] = 910;
    assert([123, 421, 910, 123, 1, 2, 8, 20, 4, 3] == (&array).peekSlice());
}

/**
 * Reverse an array in-place.
 * Params:
 *      a = array
 * Returns:
 *      reversed a[]
 */
T[] reverse(T)(T[] a) pure nothrow @nogc @safe
{
    if (a.length > 1)
    {
        const mid = (a.length + 1) >> 1;
        foreach (i; 0 .. mid)
        {
            T e = a[i];
            a[i] = a[$ - 1 - i];
            a[$ - 1 - i] = e;
        }
    }
    return a;
}

unittest
{
    int[] a1 = [];
    assert(reverse(a1) == []);
    int[] a2 = [2];
    assert(reverse(a2) == [2]);
    int[] a3 = [2,3];
    assert(reverse(a3) == [3,2]);
    int[] a4 = [2,3,4];
    assert(reverse(a4) == [4,3,2]);
    int[] a5 = [2,3,4,5];
    assert(reverse(a5) == [5,4,3,2]);
}

unittest
{
    //test toString/toChars.  Identifier is a simple object that has a usable .toString
    import dmd.identifier : Identifier;
    import core.stdc.string : strcmp;

    auto array = Array!Identifier();
    array.push(new Identifier("id1"));
    array.push(new Identifier("id2"));

    string expected = "[id1,id2]";
    assert(array.toString == expected);
    assert(strcmp(array.toChars, expected.ptr) == 0);
}
