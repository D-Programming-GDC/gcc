/**
 * Written in the D programming language.
 * This module provides Win32-specific support for sections.
 *
 * Copyright: Copyright Digital Mars 2008 - 2012.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Walter Bright, Sean Kelly, Martin Nowak
 * Source: $(DRUNTIMESRC src/rt/_sections_win64.d)
 */

module rt.sections_win64;

version (CRuntime_Microsoft):

// debug = PRINTF;
debug(PRINTF) import core.stdc.stdio;
import core.stdc.stdlib : malloc, free;
import rt.deh, rt.minfo;

struct SectionGroup
{
    static int opApply(scope int delegate(ref SectionGroup) dg)
    {
        return dg(_sections);
    }

    static int opApplyReverse(scope int delegate(ref SectionGroup) dg)
    {
        return dg(_sections);
    }

    @property immutable(ModuleInfo*)[] modules() const nothrow @nogc
    {
        return _moduleGroup.modules;
    }

    @property ref inout(ModuleGroup) moduleGroup() inout nothrow @nogc
    {
        return _moduleGroup;
    }

    version (Win64)
    @property immutable(FuncTable)[] ehTables() const nothrow @nogc
    {
        version (GNU)
        {
            // GCC exception handling does not use this function
            return [];
        }
        else
        {
            auto pbeg = cast(immutable(FuncTable)*)&_deh_beg;
            auto pend = cast(immutable(FuncTable)*)&_deh_end;
            return pbeg[0 .. pend - pbeg];
        }
    }

    @property inout(void[])[] gcRanges() inout nothrow @nogc
    {
        return _gcRanges[];
    }

private:
    ModuleGroup _moduleGroup;
    void[][] _gcRanges;
}

shared(bool) conservative;

void initSections() nothrow @nogc
{
    _sections._moduleGroup = ModuleGroup(getModuleInfos());

    // the ".data" image section includes both object file sections ".data" and ".bss"
    void[] dataSection = findImageSection(".data");
    debug(PRINTF) printf("found .data section: [%p,+%llx]\n", dataSection.ptr,
                         cast(ulong)dataSection.length);

    import rt.sections;
    conservative = !scanDataSegPrecisely();

    version (GNU)
    {
        _sections._gcRanges = (cast(void[]*) malloc((void[]).sizeof))[0..1];
        _sections._gcRanges[0] = dataSection;
    }
    else
    {
        if (conservative)
        {
            _sections._gcRanges = (cast(void[]*) malloc((void[]).sizeof))[0..1];
            _sections._gcRanges[0] = dataSection;
        }
        else
        {
            size_t count = &_DP_end - &_DP_beg;
            auto ranges = cast(void[]*) malloc(count * (void[]).sizeof);
            size_t r = 0;
            void* prev = null;
            for (size_t i = 0; i < count; i++)
            {
                auto off = (&_DP_beg)[i];
                if (off == 0) // skip zero entries added by incremental linking
                    continue; // assumes there is no D-pointer at the very beginning of .data
                void* addr = dataSection.ptr + off;
                debug(PRINTF) printf("  scan %p\n", addr);
                // combine consecutive pointers into single range
                if (prev + (void*).sizeof == addr)
                    ranges[r-1] = ranges[r-1].ptr[0 .. ranges[r-1].length + (void*).sizeof];
                else
                    ranges[r++] = (cast(void**)addr)[0..1];
                prev = addr;
            }
            _sections._gcRanges = ranges[0..r];
        }
    }
}

void finiSections() nothrow @nogc
{
    .free(cast(void*)_sections.modules.ptr);
    .free(_sections._gcRanges.ptr);
}

void[] initTLSRanges() nothrow @nogc
{
    void* pbeg;
    void* pend;
    // with VS2017 15.3.1, the linker no longer puts TLS segments into a
    //  separate image section. That way _tls_start and _tls_end no
    //  longer generate offsets into .tls, but DATA.
    // Use the TEB entry to find the start of TLS instead and read the
    //  length from the TLS directory
    version (D_InlineAsm_X86)
    {
        asm @nogc nothrow
        {
            mov EAX, _tls_index;
            mov ECX, FS:[0x2C];     // _tls_array
            mov EAX, [ECX+4*EAX];
            mov pbeg, EAX;
            add EAX, [_tls_used+4]; // end
            sub EAX, [_tls_used+0]; // start
            mov pend, EAX;
        }
        return pbeg[0 .. pend - pbeg];
    }
    else version (D_InlineAsm_X86_64)
    {
        asm @nogc nothrow
        {
            xor RAX, RAX;
            mov EAX, _tls_index;
            mov RCX, 0x58;
            mov RCX, GS:[RCX];      // _tls_array (immediate value causes fixup)
            mov RAX, [RCX+8*RAX];
            mov pbeg, RAX;
            add RAX, [_tls_used+8]; // end
            sub RAX, [_tls_used+0]; // start
            mov pend, RAX;
        }
        return pbeg[0 .. pend - pbeg];
    }
    else version (GNU_EMUTLS)
    {
        return [];
    }
    else
        static assert(false, "Architecture not supported.");
}

void finiTLSRanges(void[] rng) nothrow @nogc
{
}

version (GNU_EMUTLS)
{
    extern(C) void emutls_iterate_range (void* mem, size_t size, scope void* user) nothrow
    {
        alias GCDelegate = scope void delegate(void* pbeg, void* pend) nothrow;
        auto dg = *cast(GCDelegate*)user;
        dg(mem, mem + size);
    }
}

void scanTLSRanges(void[] rng, scope void delegate(void* pbeg, void* pend) nothrow dg) nothrow
{
    version (GNU_EMUTLS)
    {
        __emutls_iterate_memory(&emutls_iterate_range, &dg);
    }
    else
    {
        if (conservative)
        {
            dg(rng.ptr, rng.ptr + rng.length);
        }
        else
        {
            for (auto p = &_TP_beg; p < &_TP_end; )
            {
                uint beg = *p++;
                uint end = beg + cast(uint)((void*).sizeof);
                while (p < &_TP_end && *p == end)
                {
                    end += (void*).sizeof;
                    p++;
                }
                dg(rng.ptr + beg, rng.ptr + end);
            }
        }
    }
}

private:
__gshared SectionGroup _sections;

extern(C)
{
    version (GNU)
    {
        alias emutls_iterate_callback = extern(C) void function(void* mem, size_t size, void* user) nothrow;
        void __emutls_iterate_memory (emutls_iterate_callback cb, void* user) nothrow;
        extern __gshared void* __start_minfo;
        extern __gshared void* __stop_minfo;
    }
    else
    {
        extern __gshared void* _minfo_beg;
        extern __gshared void* _minfo_end;
    }
}

immutable(ModuleInfo*)[] getModuleInfos() nothrow @nogc
out (result)
{
    foreach (m; result)
        assert(m !is null);
}
body
{
    // The binutils __start symbol address is a valid ModuleInfo entry,
    // whereas the _beg address is an extra variable, not ModuleInfo.
    version (GNU)
        auto m = (cast(immutable(ModuleInfo*)*)&__start_minfo)[0 .. &__stop_minfo - &__start_minfo];
    else
        auto m = (cast(immutable(ModuleInfo*)*)&_minfo_beg)[1 .. &_minfo_end - &_minfo_beg];
    /* Because of alignment inserted by the linker, various null pointers
     * are there. We need to filter them out.
     */
    auto p = m.ptr;
    auto pend = m.ptr + m.length;

    // count non-null pointers
    size_t cnt;
    for (; p < pend; ++p)
    {
        if (*p !is null) ++cnt;
    }

    auto result = (cast(immutable(ModuleInfo)**).malloc(cnt * size_t.sizeof))[0 .. cnt];

    p = m.ptr;
    cnt = 0;
    for (; p < pend; ++p)
        if (*p !is null) result[cnt++] = *p;

    return cast(immutable)result;
}

extern(C)
{
    /* Symbols created by the compiler/linker and inserted into the
     * object file that 'bracket' sections.
     */
    extern __gshared
    {
        void* __ImageBase;

        void* _deh_beg;
        void* _deh_end;

        uint _DP_beg;
        uint _DP_end;
        uint _TP_beg;
        uint _TP_end;

        void*[2] _tls_used; // start, end
        int _tls_index;
    }
}

/////////////////////////////////////////////////////////////////////

enum IMAGE_DOS_SIGNATURE = 0x5A4D;      // MZ

struct IMAGE_DOS_HEADER // DOS .EXE header
{
    ushort   e_magic;    // Magic number
    ushort[29] e_res2;   // Reserved ushorts
    int      e_lfanew;   // File address of new exe header
}

struct IMAGE_FILE_HEADER
{
    ushort Machine;
    ushort NumberOfSections;
    uint   TimeDateStamp;
    uint   PointerToSymbolTable;
    uint   NumberOfSymbols;
    ushort SizeOfOptionalHeader;
    ushort Characteristics;
}

struct IMAGE_NT_HEADERS
{
    uint Signature;
    IMAGE_FILE_HEADER FileHeader;
    // optional header follows
}

struct IMAGE_SECTION_HEADER
{
    char[8] Name;
    union {
        uint   PhysicalAddress;
        uint   VirtualSize;
    }
    uint   VirtualAddress;
    uint   SizeOfRawData;
    uint   PointerToRawData;
    uint   PointerToRelocations;
    uint   PointerToLinenumbers;
    ushort NumberOfRelocations;
    ushort NumberOfLinenumbers;
    uint   Characteristics;
}

bool compareSectionName(ref IMAGE_SECTION_HEADER section, string name) nothrow @nogc
{
    if (name[] != section.Name[0 .. name.length])
        return false;
    return name.length == 8 || section.Name[name.length] == 0;
}

void[] findImageSection(string name) nothrow @nogc
{
    if (name.length > 8) // section name from string table not supported
        return null;
    IMAGE_DOS_HEADER* doshdr = cast(IMAGE_DOS_HEADER*) &__ImageBase;
    if (doshdr.e_magic != IMAGE_DOS_SIGNATURE)
        return null;

    auto nthdr = cast(IMAGE_NT_HEADERS*)(cast(void*)doshdr + doshdr.e_lfanew);
    auto sections = cast(IMAGE_SECTION_HEADER*)(cast(void*)nthdr + IMAGE_NT_HEADERS.sizeof + nthdr.FileHeader.SizeOfOptionalHeader);
    for (ushort i = 0; i < nthdr.FileHeader.NumberOfSections; i++)
        if (compareSectionName (sections[i], name))
            return (cast(void*)&__ImageBase + sections[i].VirtualAddress)[0 .. sections[i].VirtualSize];

    return null;
}
