/**
 * Contains the garbage collector implementation.
 *
 * Copyright: Copyright Digital Mars 2001 - 2016.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright, David Friedman, Sean Kelly
 */

/*          Copyright Digital Mars 2005 - 2016.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.impl.conservative.gc;

// D Programming Language Garbage Collector implementation

/************** Debugging ***************************/

//debug = PRINTF;               // turn on printf's
//debug = PARALLEL_PRINTF;      // turn on printf's
//debug = COLLECT_PRINTF;       // turn on printf's
//debug = MARK_PRINTF;          // turn on printf's
//debug = PRINTF_TO_FILE;       // redirect printf's ouptut to file "gcx.log"
//debug = LOGGING;              // log allocations / frees
//debug = MEMSTOMP;             // stomp on memory
//debug = SENTINEL;             // add underrun/overrrun protection
                                // NOTE: this needs to be enabled globally in the makefiles
                                // (-debug=SENTINEL) to pass druntime's unittests.
//debug = PTRCHECK;             // more pointer checking
//debug = PTRCHECK2;            // thorough but slow pointer checking
//debug = INVARIANT;            // enable invariants
//debug = PROFILE_API;          // profile API calls for config.profile > 1

/***************************************************/
version = COLLECT_PARALLEL;  // parallel scanning

import gc.bits;
import gc.os;
import core.gc.config;
import core.gc.gcinterface;

import rt.util.container.treap;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memcpy, memset, memmove;
import core.bitop;
import core.thread;
static import core.memory;

version (GNU) import gcc.builtins;

debug (PRINTF_TO_FILE) import core.stdc.stdio : sprintf, fprintf, fopen, fflush, FILE;
else                   import core.stdc.stdio : sprintf, printf; // needed to output profiling results

import core.time;
alias currTime = MonoTime.currTime;

// Track total time spent preparing for GC,
// marking, sweeping and recovering pages.
__gshared Duration prepTime;
__gshared Duration markTime;
__gshared Duration sweepTime;
__gshared Duration pauseTime;
__gshared Duration maxPauseTime;
__gshared Duration maxCollectionTime;
__gshared size_t numCollections;
__gshared size_t maxPoolMemory;

__gshared long numMallocs;
__gshared long numFrees;
__gshared long numReallocs;
__gshared long numExtends;
__gshared long numOthers;
__gshared long mallocTime; // using ticks instead of MonoTime for better performance
__gshared long freeTime;
__gshared long reallocTime;
__gshared long extendTime;
__gshared long otherTime;
__gshared long lockTime;

ulong bytesAllocated;   // thread local counter

private
{
    extern (C)
    {
        // to allow compilation of this module without access to the rt package,
        //  make these functions available from rt.lifetime
        void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
        int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;

        // Declared as an extern instead of importing core.exception
        // to avoid inlining - see issue 13725.
        void onInvalidMemoryOperationError(void* pretend_sideffect = null) @trusted pure nothrow @nogc;
        void onOutOfMemoryErrorNoGC() @trusted nothrow @nogc;
    }

    enum
    {
        OPFAIL = ~cast(size_t)0
    }
}

alias GC gc_t;

/* ============================ GC =============================== */

// register GC in C constructor (_STI_)
extern(C) pragma(crt_constructor) void _d_register_conservative_gc()
{
    import core.gc.registry;
    registerGCFactory("conservative", &initialize);
}

extern(C) pragma(crt_constructor) void _d_register_precise_gc()
{
    import core.gc.registry;
    registerGCFactory("precise", &initialize_precise);
}

private GC initialize()
{
    import core.stdc.string: memcpy;

    auto p = cstdlib.malloc(__traits(classInstanceSize, ConservativeGC));

    if (!p)
        onOutOfMemoryErrorNoGC();

    auto init = typeid(ConservativeGC).initializer();
    assert(init.length == __traits(classInstanceSize, ConservativeGC));
    auto instance = cast(ConservativeGC) memcpy(p, init.ptr, init.length);
    instance.__ctor();

    return instance;
}

private GC initialize_precise()
{
    ConservativeGC.isPrecise = true;
    return initialize();
}

class ConservativeGC : GC
{
    // For passing to debug code (not thread safe)
    __gshared size_t line;
    __gshared char*  file;

    Gcx *gcx;                   // implementation

    import core.internal.spinlock;
    static gcLock = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);
    static bool _inFinalizer;
    __gshared bool isPrecise = false;

    // lock GC, throw InvalidMemoryOperationError on recursive locking during finalization
    static void lockNR() @nogc nothrow
    {
        if (_inFinalizer)
            onInvalidMemoryOperationError();
        gcLock.lock();
    }

    this()
    {
        //config is assumed to have already been initialized

        gcx = cast(Gcx*)cstdlib.calloc(1, Gcx.sizeof);
        if (!gcx)
            onOutOfMemoryErrorNoGC();
        gcx.initialize();

        if (config.initReserve)
            gcx.reserve(config.initReserve << 20);
        if (config.disable)
            gcx.disabled++;
    }


    ~this()
    {
        version (linux)
        {
            //debug(PRINTF) printf("Thread %x ", pthread_self());
            //debug(PRINTF) printf("GC.Dtor()\n");
        }

        if (gcx)
        {
            gcx.Dtor();
            cstdlib.free(gcx);
            gcx = null;
        }
        // TODO: cannot free as memory is overwritten and
        //  the monitor is still read in rt_finalize (called by destroy)
        // cstdlib.free(cast(void*) this);
    }


    void enable()
    {
        static void go(Gcx* gcx) nothrow
        {
            assert(gcx.disabled > 0);
            gcx.disabled--;
        }
        runLocked!(go, otherTime, numOthers)(gcx);
    }


    void disable()
    {
        static void go(Gcx* gcx) nothrow
        {
            gcx.disabled++;
        }
        runLocked!(go, otherTime, numOthers)(gcx);
    }


    auto runLocked(alias func, Args...)(auto ref Args args)
    {
        debug(PROFILE_API) immutable tm = (config.profile > 1 ? currTime.ticks : 0);
        lockNR();
        scope (failure) gcLock.unlock();
        debug(PROFILE_API) immutable tm2 = (config.profile > 1 ? currTime.ticks : 0);

        static if (is(typeof(func(args)) == void))
            func(args);
        else
            auto res = func(args);

        debug(PROFILE_API) if (config.profile > 1)
            lockTime += tm2 - tm;
        gcLock.unlock();

        static if (!is(typeof(func(args)) == void))
            return res;
    }


    auto runLocked(alias func, alias time, alias count, Args...)(auto ref Args args)
    {
        debug(PROFILE_API) immutable tm = (config.profile > 1 ? currTime.ticks : 0);
        lockNR();
        scope (failure) gcLock.unlock();
        debug(PROFILE_API) immutable tm2 = (config.profile > 1 ? currTime.ticks : 0);

        static if (is(typeof(func(args)) == void))
            func(args);
        else
            auto res = func(args);

        debug(PROFILE_API) if (config.profile > 1)
        {
            count++;
            immutable now = currTime.ticks;
            lockTime += tm2 - tm;
            time += now - tm2;
        }
        gcLock.unlock();

        static if (!is(typeof(func(args)) == void))
            return res;
    }


    uint getAttr(void* p) nothrow
    {
        if (!p)
        {
            return 0;
        }

        static uint go(Gcx* gcx, void* p) nothrow
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                p = sentinel_sub(p);
                if (p != pool.findBase(p))
                    return 0;
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = pool.getBits(biti);
            }
            return oldb;
        }

        return runLocked!(go, otherTime, numOthers)(gcx, p);
    }


    uint setAttr(void* p, uint mask) nothrow
    {
        if (!p)
        {
            return 0;
        }

        static uint go(Gcx* gcx, void* p, uint mask) nothrow
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                p = sentinel_sub(p);
                if (p != pool.findBase(p))
                    return 0;
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = pool.getBits(biti);
                pool.setBits(biti, mask);
            }
            return oldb;
        }

        return runLocked!(go, otherTime, numOthers)(gcx, p, mask);
    }


    uint clrAttr(void* p, uint mask) nothrow
    {
        if (!p)
        {
            return 0;
        }

        static uint go(Gcx* gcx, void* p, uint mask) nothrow
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                p = sentinel_sub(p);
                if (p != pool.findBase(p))
                    return 0;
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = pool.getBits(biti);
                pool.clrBits(biti, mask);
            }
            return oldb;
        }

        return runLocked!(go, otherTime, numOthers)(gcx, p, mask);
    }


    void *malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        if (!size)
        {
            return null;
        }

        size_t localAllocSize = void;

        auto p = runLocked!(mallocNoSync, mallocTime, numMallocs)(size, bits, localAllocSize, ti);

        if (!(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, localAllocSize - size);
        }

        return p;
    }


    //
    //
    //
    private void *mallocNoSync(size_t size, uint bits, ref size_t alloc_size, const TypeInfo ti = null) nothrow
    {
        assert(size != 0);

        debug(PRINTF)
            printf("GC::malloc(gcx = %p, size = %d bits = %x, ti = %s)\n", gcx, size, bits, debugTypeName(ti).ptr);

        assert(gcx);
        //debug(PRINTF) printf("gcx.self = %x, pthread_self() = %x\n", gcx.self, pthread_self());

        auto p = gcx.alloc(size + SENTINEL_EXTRA, alloc_size, bits, ti);
        if (!p)
            onOutOfMemoryErrorNoGC();

        debug (SENTINEL)
        {
            p = sentinel_add(p);
            sentinel_init(p, size);
            alloc_size = size;
        }
        gcx.leakDetector.log_malloc(p, size);
        bytesAllocated += alloc_size;

        debug(PRINTF) printf("  => p = %p\n", p);
        return p;
    }


    BlkInfo qalloc( size_t size, uint bits, const TypeInfo ti) nothrow
    {

        if (!size)
        {
            return BlkInfo.init;
        }

        BlkInfo retval;

        retval.base = runLocked!(mallocNoSync, mallocTime, numMallocs)(size, bits, retval.size, ti);

        if (!(bits & BlkAttr.NO_SCAN))
        {
            memset(retval.base + size, 0, retval.size - size);
        }

        retval.attr = bits;
        return retval;
    }


    void *calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        if (!size)
        {
            return null;
        }

        size_t localAllocSize = void;

        auto p = runLocked!(mallocNoSync, mallocTime, numMallocs)(size, bits, localAllocSize, ti);

        memset(p, 0, size);
        if (!(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, localAllocSize - size);
        }

        return p;
    }


    void *realloc(void *p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        size_t localAllocSize = void;
        auto oldp = p;

        p = runLocked!(reallocNoSync, mallocTime, numMallocs)(p, size, bits, localAllocSize, ti);

        if (p && p !is oldp && !(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, localAllocSize - size);
        }

        return p;
    }


    //
    // bits will be set to the resulting bits of the new block
    //
    private void *reallocNoSync(void *p, size_t size, ref uint bits, ref size_t alloc_size, const TypeInfo ti = null) nothrow
    {
        if (!size)
        {
            if (p)
                freeNoSync(p);
            alloc_size = 0;
            return null;
        }
        if (!p)
            return mallocNoSync(size, bits, alloc_size, ti);

        debug(PRINTF) printf("GC::realloc(p = %p, size = %llu)\n", p, cast(ulong)size);

        Pool *pool = gcx.findPool(p);
        if (!pool)
            return null;

        size_t psize;
        size_t biti;

        debug(SENTINEL)
        {
            void* q = p;
            p = sentinel_sub(p);
            bool alwaysMalloc = true;
        }
        else
        {
            alias q = p;
            enum alwaysMalloc = false;
        }

        void* doMalloc()
        {
            if (!bits)
                bits = pool.getBits(biti);

            void* p2 = mallocNoSync(size, bits, alloc_size, ti);
            debug (SENTINEL)
                psize = sentinel_size(q, psize);
            if (psize < size)
                size = psize;
            //debug(PRINTF) printf("\tcopying %d bytes\n",size);
            memcpy(p2, q, size);
            freeNoSync(q);
            return p2;
        }

        if (pool.isLargeObject)
        {
            auto lpool = cast(LargeObjectPool*) pool;
            auto psz = lpool.getPages(p);     // get allocated size
            if (psz == 0)
                return null;      // interior pointer
            psize = psz * PAGESIZE;

            alias pagenum = biti; // happens to be the same, but rename for clarity
            pagenum = lpool.pagenumOf(p);

            if (size <= PAGESIZE / 2 || alwaysMalloc)
                return doMalloc(); // switching from large object pool to small object pool

            auto newsz = lpool.numPages(size);
            if (newsz == psz)
            {
                // nothing to do
            }
            else if (newsz < psz)
            {
                // Shrink in place
                debug (MEMSTOMP) memset(p + size, 0xF2, psize - size);
                lpool.freePages(pagenum + newsz, psz - newsz);
                lpool.mergeFreePageOffsets!(false, true)(pagenum + newsz, psz - newsz);
                lpool.bPageOffsets[pagenum] = cast(uint) newsz;
            }
            else if (pagenum + newsz <= pool.npages)
            {
                // Attempt to expand in place (TODO: merge with extend)
                if (lpool.pagetable[pagenum + psz] != B_FREE)
                    return doMalloc();

                auto newPages = newsz - psz;
                auto freesz = lpool.bPageOffsets[pagenum + psz];
                if (freesz < newPages)
                    return doMalloc(); // free range too small

                debug (MEMSTOMP) memset(p + psize, 0xF0, size - psize);
                debug (PRINTF) printFreeInfo(pool);
                memset(&lpool.pagetable[pagenum + psz], B_PAGEPLUS, newPages);
                lpool.bPageOffsets[pagenum] = cast(uint) newsz;
                for (auto offset = psz; offset < newsz; offset++)
                    lpool.bPageOffsets[pagenum + offset] = cast(uint) offset;
                if (freesz > newPages)
                    lpool.setFreePageOffsets(pagenum + newsz, freesz - newPages);
                gcx.usedLargePages += newPages;
                lpool.freepages -= newPages;
                debug (PRINTF) printFreeInfo(pool);
            }
            else
                return doMalloc(); // does not fit into current pool

            alloc_size = newsz * PAGESIZE;
        }
        else
        {
            psize = (cast(SmallObjectPool*) pool).getSize(p);   // get allocated bin size
            if (psize == 0)
                return null;    // interior pointer
            biti = cast(size_t)(p - pool.baseAddr) >> Pool.ShiftBy.Small;
            if (pool.freebits.test (biti))
                return null;

            // allocate if new size is bigger or less than half
            if (psize < size || psize > size * 2 || alwaysMalloc)
                return doMalloc();

            alloc_size = psize;
            if (isPrecise)
                pool.setPointerBitmapSmall(p, size, psize, bits, ti);
        }

        if (bits)
        {
            pool.clrBits(biti, ~BlkAttr.NONE);
            pool.setBits(biti, bits);

        }
        return p;
    }


    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        return runLocked!(extendNoSync, extendTime, numExtends)(p, minsize, maxsize, ti);
    }


    //
    //
    //
    private size_t extendNoSync(void* p, size_t minsize, size_t maxsize, const TypeInfo ti = null) nothrow
    in
    {
        assert(minsize <= maxsize);
    }
    do
    {
        debug(PRINTF) printf("GC::extend(p = %p, minsize = %zu, maxsize = %zu)\n", p, minsize, maxsize);
        debug (SENTINEL)
        {
            return 0;
        }
        else
        {
            auto pool = gcx.findPool(p);
            if (!pool || !pool.isLargeObject)
                return 0;

            auto lpool = cast(LargeObjectPool*) pool;
            size_t pagenum = lpool.pagenumOf(p);
            if (lpool.pagetable[pagenum] != B_PAGE)
                return 0;

            size_t psz = lpool.bPageOffsets[pagenum];
            assert(psz > 0);

            auto minsz = lpool.numPages(minsize);
            auto maxsz = lpool.numPages(maxsize);

            if (pagenum + psz >= lpool.npages)
                return 0;
            if (lpool.pagetable[pagenum + psz] != B_FREE)
                return 0;

            size_t freesz = lpool.bPageOffsets[pagenum + psz];
            if (freesz < minsz)
                return 0;
            size_t sz = freesz > maxsz ? maxsz : freesz;
            debug (MEMSTOMP) memset(pool.baseAddr + (pagenum + psz) * PAGESIZE, 0xF0, sz * PAGESIZE);
            memset(lpool.pagetable + pagenum + psz, B_PAGEPLUS, sz);
            lpool.bPageOffsets[pagenum] = cast(uint) (psz + sz);
            for (auto offset = psz; offset < psz + sz; offset++)
                lpool.bPageOffsets[pagenum + offset] = cast(uint) offset;
            if (freesz > sz)
                lpool.setFreePageOffsets(pagenum + psz + sz, freesz - sz);
            lpool.freepages -= sz;
            gcx.usedLargePages += sz;
            return (psz + sz) * PAGESIZE;
        }
    }


    size_t reserve(size_t size) nothrow
    {
        if (!size)
        {
            return 0;
        }

        return runLocked!(reserveNoSync, otherTime, numOthers)(size);
    }


    //
    //
    //
    private size_t reserveNoSync(size_t size) nothrow
    {
        assert(size != 0);
        assert(gcx);

        return gcx.reserve(size);
    }


    void free(void *p) nothrow @nogc
    {
        if (!p || _inFinalizer)
        {
            return;
        }

        return runLocked!(freeNoSync, freeTime, numFrees)(p);
    }


    //
    //
    //
    private void freeNoSync(void *p) nothrow @nogc
    {
        debug(PRINTF) printf("Freeing %p\n", cast(size_t) p);
        assert (p);

        Pool*  pool;
        size_t pagenum;
        Bins   bin;
        size_t biti;

        // Find which page it is in
        pool = gcx.findPool(p);
        if (!pool)                              // if not one of ours
            return;                             // ignore

        pagenum = pool.pagenumOf(p);

        debug(PRINTF) printf("pool base = %p, PAGENUM = %d of %d, bin = %d\n", pool.baseAddr, pagenum, pool.npages, pool.pagetable[pagenum]);
        debug(PRINTF) if (pool.isLargeObject) printf("Block size = %d\n", pool.bPageOffsets[pagenum]);

        bin = cast(Bins)pool.pagetable[pagenum];

        // Verify that the pointer is at the beginning of a block,
        //  no action should be taken if p is an interior pointer
        if (bin > B_PAGE) // B_PAGEPLUS or B_FREE
            return;
        size_t off = (sentinel_sub(p) - pool.baseAddr);
        size_t base = baseOffset(off, bin);
        if (off != base)
            return;

        sentinel_Invariant(p);
        p = sentinel_sub(p);

        if (pool.isLargeObject)              // if large alloc
        {
            biti = cast(size_t)(p - pool.baseAddr) >> pool.ShiftBy.Large;
            assert(bin == B_PAGE);
            auto lpool = cast(LargeObjectPool*) pool;

            // Free pages
            size_t npages = lpool.bPageOffsets[pagenum];
            debug (MEMSTOMP) memset(p, 0xF2, npages * PAGESIZE);
            lpool.freePages(pagenum, npages);
            lpool.mergeFreePageOffsets!(true, true)(pagenum, npages);
        }
        else
        {
            biti = cast(size_t)(p - pool.baseAddr) >> pool.ShiftBy.Small;
            if (pool.freebits.test (biti))
                return;
            // Add to free list
            List *list = cast(List*)p;

            debug (MEMSTOMP) memset(p, 0xF2, binsize[bin]);

            // in case the page hasn't been recovered yet, don't add the object to the free list
            if (!gcx.recoverPool[bin] || pool.binPageChain[pagenum] == Pool.PageRecovered)
            {
                list.next = gcx.bucket[bin];
                list.pool = pool;
                gcx.bucket[bin] = list;
            }
            pool.freebits.set(biti);
        }
        pool.clrBits(biti, ~BlkAttr.NONE);

        gcx.leakDetector.log_free(sentinel_add(p));
    }


    void* addrOf(void *p) nothrow @nogc
    {
        if (!p)
        {
            return null;
        }

        return runLocked!(addrOfNoSync, otherTime, numOthers)(p);
    }


    //
    //
    //
    void* addrOfNoSync(void *p) nothrow @nogc
    {
        if (!p)
        {
            return null;
        }

        auto q = gcx.findBase(p);
        if (q)
            q = sentinel_add(q);
        return q;
    }


    size_t sizeOf(void *p) nothrow @nogc
    {
        if (!p)
        {
            return 0;
        }

        return runLocked!(sizeOfNoSync, otherTime, numOthers)(p);
    }


    //
    //
    //
    private size_t sizeOfNoSync(void *p) nothrow @nogc
    {
        assert (p);

        debug (SENTINEL)
        {
            p = sentinel_sub(p);
            size_t size = gcx.findSize(p);
            return size ? size - SENTINEL_EXTRA : 0;
        }
        else
        {
            size_t size = gcx.findSize(p);
            return size;
        }
    }


    BlkInfo query(void *p) nothrow
    {
        if (!p)
        {
            BlkInfo i;
            return  i;
        }

        return runLocked!(queryNoSync, otherTime, numOthers)(p);
    }

    //
    //
    //
    BlkInfo queryNoSync(void *p) nothrow
    {
        assert(p);

        BlkInfo info = gcx.getInfo(p);
        debug(SENTINEL)
        {
            if (info.base)
            {
                info.base = sentinel_add(info.base);
                info.size = *sentinel_psize(info.base);
            }
        }
        return info;
    }


    /**
     * Verify that pointer p:
     *  1) belongs to this memory pool
     *  2) points to the start of an allocated piece of memory
     *  3) is not on a free list
     */
    void check(void *p) nothrow
    {
        if (!p)
        {
            return;
        }

        return runLocked!(checkNoSync, otherTime, numOthers)(p);
    }


    //
    //
    //
    private void checkNoSync(void *p) nothrow
    {
        assert(p);

        sentinel_Invariant(p);
        debug (PTRCHECK)
        {
            Pool*  pool;
            size_t pagenum;
            Bins   bin;

            p = sentinel_sub(p);
            pool = gcx.findPool(p);
            assert(pool);
            pagenum = pool.pagenumOf(p);
            bin = cast(Bins)pool.pagetable[pagenum];
            assert(bin <= B_PAGE);
            assert(p == cast(void*)baseOffset(cast(size_t)p, bin));

            debug (PTRCHECK2)
            {
                if (bin < B_PAGE)
                {
                    // Check that p is not on a free list
                    List *list;

                    for (list = gcx.bucket[bin]; list; list = list.next)
                    {
                        assert(cast(void*)list != p);
                    }
                }
            }
        }
    }


    void addRoot(void *p) nothrow @nogc
    {
        if (!p)
        {
            return;
        }

        gcx.addRoot(p);
    }


    void removeRoot(void *p) nothrow @nogc
    {
        if (!p)
        {
            return;
        }

        gcx.removeRoot(p);
    }


    @property RootIterator rootIter() @nogc
    {
        return &gcx.rootsApply;
    }


    void addRange(void *p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        if (!p || !sz)
        {
            return;
        }

        gcx.addRange(p, p + sz, ti);
    }


    void removeRange(void *p) nothrow @nogc
    {
        if (!p)
        {
            return;
        }

        gcx.removeRange(p);
    }


    @property RangeIterator rangeIter() @nogc
    {
        return &gcx.rangesApply;
    }


    void runFinalizers(in void[] segment) nothrow
    {
        static void go(Gcx* gcx, in void[] segment) nothrow
        {
            gcx.runFinalizers(segment);
        }
        return runLocked!(go, otherTime, numOthers)(gcx, segment);
    }


    bool inFinalizer() nothrow
    {
        return _inFinalizer;
    }


    void collect() nothrow
    {
        fullCollect();
    }


    void collectNoStack() nothrow
    {
        fullCollectNoStack();
    }


    /**
     * Do full garbage collection.
     * Return number of pages free'd.
     */
    size_t fullCollect() nothrow
    {
        debug(PRINTF) printf("GC.fullCollect()\n");

        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.
        static size_t go(Gcx* gcx) nothrow
        {
            return gcx.fullcollect();
        }
        immutable result = runLocked!go(gcx);

        version (none)
        {
            GCStats stats;

            getStats(stats);
            debug(PRINTF) printf("heapSize = %zx, freeSize = %zx\n",
                stats.heapSize, stats.freeSize);
        }

        gcx.leakDetector.log_collect();
        return result;
    }


    /**
     * do full garbage collection ignoring roots
     */
    void fullCollectNoStack() nothrow
    {
        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.
        static size_t go(Gcx* gcx) nothrow
        {
            return gcx.fullcollect(true);
        }
        runLocked!go(gcx);
    }


    void minimize() nothrow
    {
        static void go(Gcx* gcx) nothrow
        {
            gcx.minimize();
        }
        runLocked!(go, otherTime, numOthers)(gcx);
    }


    core.memory.GC.Stats stats() nothrow
    {
        typeof(return) ret;

        runLocked!(getStatsNoSync, otherTime, numOthers)(ret);

        return ret;
    }


    core.memory.GC.ProfileStats profileStats() nothrow
    {
        typeof(return) ret;

        ret.numCollections = numCollections;
        ret.totalCollectionTime = prepTime + markTime + sweepTime;
        ret.totalPauseTime = pauseTime;
        ret.maxCollectionTime = maxCollectionTime;
        ret.maxPauseTime = maxPauseTime;

        return ret;
    }

    //
    //
    //
    private void getStatsNoSync(out core.memory.GC.Stats stats) nothrow
    {
        foreach (pool; gcx.pooltable[0 .. gcx.npools])
        {
            foreach (bin; pool.pagetable[0 .. pool.npages])
            {
                if (bin == B_FREE)
                    stats.freeSize += PAGESIZE;
                else
                    stats.usedSize += PAGESIZE;
            }
        }

        size_t freeListSize;
        foreach (n; 0 .. B_PAGE)
        {
            immutable sz = binsize[n];
            for (List *list = gcx.bucket[n]; list; list = list.next)
                freeListSize += sz;

            foreach (pool; gcx.pooltable[0 .. gcx.npools])
            {
                if (pool.isLargeObject)
                    continue;
                for (uint pn = pool.recoverPageFirst[n]; pn < pool.npages; pn = pool.binPageChain[pn])
                {
                    const bitbase = pn * PAGESIZE / 16;
                    const top = PAGESIZE - sz + 1; // ensure <size> bytes available even if unaligned
                    for (size_t u = 0; u < top; u += sz)
                        if (pool.freebits.test(bitbase + u / 16))
                            freeListSize += sz;
                }
            }
        }

        stats.usedSize -= freeListSize;
        stats.freeSize += freeListSize;
        stats.allocatedInCurrentThread = bytesAllocated;
    }
}


/* ============================ Gcx =============================== */

enum
{   PAGESIZE =    4096,
    POOLSIZE =   (4096*256),
}


enum
{
    B_16,
    B_32,
    B_48,
    B_64,
    B_96,
    B_128,
    B_176,
    B_256,
    B_368,
    B_512,
    B_816,
    B_1024,
    B_1360,
    B_2048,
    B_NUMSMALL,

    B_PAGE = B_NUMSMALL,// start of large alloc
    B_PAGEPLUS,         // continuation of large alloc
    B_FREE,             // free page
    B_MAX,
}


alias ubyte Bins;


struct List
{
    List *next;
    Pool *pool;
}

// non power of two sizes optimized for small remainder within page (<= 64 bytes)
immutable short[B_NUMSMALL + 1] binsize = [ 16, 32, 48, 64, 96, 128, 176, 256, 368, 512, 816, 1024, 1360, 2048, 4096 ];
immutable short[PAGESIZE / 16][B_NUMSMALL + 1] binbase = calcBinBase();

short[PAGESIZE / 16][B_NUMSMALL + 1] calcBinBase()
{
    short[PAGESIZE / 16][B_NUMSMALL + 1] bin;

    foreach (i, size; binsize)
    {
        short end = (PAGESIZE / size) * size;
        short bsz = size / 16;
        foreach (off; 0..PAGESIZE/16)
        {
            // add the remainder to the last bin, so no check during scanning
            //  is needed if a false pointer targets that area
            const base = (off - off % bsz) * 16;
            bin[i][off] = cast(short)(base < end ? base : end - size);
        }
    }
    return bin;
}

size_t baseOffset(size_t offset, Bins bin) @nogc nothrow
{
    assert(bin <= B_PAGE);
    return (offset & ~(PAGESIZE - 1)) + binbase[bin][(offset & (PAGESIZE - 1)) >> 4];
}

alias PageBits = GCBits.wordtype[PAGESIZE / 16 / GCBits.BITS_PER_WORD];
static assert(PAGESIZE % (GCBits.BITS_PER_WORD * 16) == 0);

// bitmask with bits set at base offsets of objects
immutable PageBits[B_NUMSMALL] baseOffsetBits = (){
    PageBits[B_NUMSMALL] bits;
    foreach (bin; 0..B_NUMSMALL)
    {
        size_t size = binsize[bin];
        const top = PAGESIZE - size + 1; // ensure <size> bytes available even if unaligned
        for (size_t u = 0; u < top; u += size)
        {
            size_t biti = u / 16;
            size_t off = biti / GCBits.BITS_PER_WORD;
            size_t mod = biti % GCBits.BITS_PER_WORD;
            bits[bin][off] |= GCBits.BITS_1 << mod;
        }
    }
    return bits;
}();

private void set(ref PageBits bits, size_t i) @nogc pure nothrow
{
    assert(i < PageBits.sizeof * 8);
    bts(bits.ptr, i);
}

/* ============================ Gcx =============================== */

struct Gcx
{
    import core.internal.spinlock;
    auto rootsLock = shared(AlignedSpinLock)(SpinLock.Contention.brief);
    auto rangesLock = shared(AlignedSpinLock)(SpinLock.Contention.brief);
    Treap!Root roots;
    Treap!Range ranges;

    debug(INVARIANT) bool initialized;
    debug(INVARIANT) bool inCollection;
    uint disabled; // turn off collections if >0

    import gc.pooltable;
    private @property size_t npools() pure const nothrow { return pooltable.length; }
    PoolTable!Pool pooltable;

    List*[B_NUMSMALL] bucket; // free list for each small size

    // run a collection when reaching those thresholds (number of used pages)
    float smallCollectThreshold, largeCollectThreshold;
    uint usedSmallPages, usedLargePages;
    // total number of mapped pages
    uint mappedPages;

    debug (LOGGING)
        LeakDetector leakDetector;
    else
        alias leakDetector = LeakDetector;

    SmallObjectPool*[B_NUMSMALL] recoverPool;

    void initialize()
    {
        (cast(byte*)&this)[0 .. Gcx.sizeof] = 0;
        leakDetector.initialize(&this);
        roots.initialize();
        ranges.initialize();
        smallCollectThreshold = largeCollectThreshold = 0.0f;
        usedSmallPages = usedLargePages = 0;
        mappedPages = 0;
        //printf("gcx = %p, self = %x\n", &this, self);
        debug(INVARIANT) initialized = true;
    }


    void Dtor()
    {
        if (config.profile)
        {
            printf("\tNumber of collections:  %llu\n", cast(ulong)numCollections);
            printf("\tTotal GC prep time:  %lld milliseconds\n",
                   prepTime.total!("msecs"));
            printf("\tTotal mark time:  %lld milliseconds\n",
                   markTime.total!("msecs"));
            printf("\tTotal sweep time:  %lld milliseconds\n",
                   sweepTime.total!("msecs"));
            long maxPause = maxPauseTime.total!("msecs");
            printf("\tMax Pause Time:  %lld milliseconds\n", maxPause);
            long gcTime = (sweepTime + markTime + prepTime).total!("msecs");
            printf("\tGrand total GC time:  %lld milliseconds\n", gcTime);
            long pauseTime = (markTime + prepTime).total!("msecs");

            char[30] apitxt = void;
            apitxt[0] = 0;
            debug(PROFILE_API) if (config.profile > 1)
            {
                static Duration toDuration(long dur)
                {
                    return MonoTime(dur) - MonoTime(0);
                }

                printf("\n");
                printf("\tmalloc:  %llu calls, %lld ms\n", cast(ulong)numMallocs, toDuration(mallocTime).total!"msecs");
                printf("\trealloc: %llu calls, %lld ms\n", cast(ulong)numReallocs, toDuration(reallocTime).total!"msecs");
                printf("\tfree:    %llu calls, %lld ms\n", cast(ulong)numFrees, toDuration(freeTime).total!"msecs");
                printf("\textend:  %llu calls, %lld ms\n", cast(ulong)numExtends, toDuration(extendTime).total!"msecs");
                printf("\tother:   %llu calls, %lld ms\n", cast(ulong)numOthers, toDuration(otherTime).total!"msecs");
                printf("\tlock time: %lld ms\n", toDuration(lockTime).total!"msecs");

                long apiTime = mallocTime + reallocTime + freeTime + extendTime + otherTime + lockTime;
                printf("\tGC API: %lld ms\n", toDuration(apiTime).total!"msecs");
                sprintf(apitxt.ptr, " API%5ld ms", toDuration(apiTime).total!"msecs");
            }

            printf("GC summary:%5lld MB,%5lld GC%5lld ms, Pauses%5lld ms <%5lld ms%s\n",
                   cast(long) maxPoolMemory >> 20, cast(ulong)numCollections, gcTime,
                   pauseTime, maxPause, apitxt.ptr);
        }

        version (COLLECT_PARALLEL)
            stopScanThreads();

        debug(INVARIANT) initialized = false;

        for (size_t i = 0; i < npools; i++)
        {
            Pool *pool = pooltable[i];
            mappedPages -= pool.npages;
            pool.Dtor();
            cstdlib.free(pool);
        }
        assert(!mappedPages);
        pooltable.Dtor();

        roots.removeAll();
        ranges.removeAll();
        toscanConservative.reset();
        toscanPrecise.reset();
    }


    void Invariant() const { }

    debug(INVARIANT)
    invariant()
    {
        if (initialized)
        {
            //printf("Gcx.invariant(): this = %p\n", &this);
            pooltable.Invariant();
            for (size_t p = 0; p < pooltable.length; p++)
                if (pooltable.pools[p].isLargeObject)
                    (cast(LargeObjectPool*)(pooltable.pools[p])).Invariant();
                else
                    (cast(SmallObjectPool*)(pooltable.pools[p])).Invariant();

            if (!inCollection)
                (cast()rangesLock).lock();
            foreach (range; ranges)
            {
                assert(range.pbot);
                assert(range.ptop);
                assert(range.pbot <= range.ptop);
            }
            if (!inCollection)
                (cast()rangesLock).unlock();

            for (size_t i = 0; i < B_NUMSMALL; i++)
            {
                size_t j = 0;
                List* prev, pprev, ppprev; // keep a short history to inspect in the debugger
                for (auto list = cast(List*)bucket[i]; list; list = list.next)
                {
                    auto pool = list.pool;
                    auto biti = cast(size_t)(cast(void*)list - pool.baseAddr) >> Pool.ShiftBy.Small;
                    assert(pool.freebits.test(biti));
                }
            }
        }
    }


    /**
     *
     */
    void addRoot(void *p) nothrow @nogc
    {
        rootsLock.lock();
        scope (failure) rootsLock.unlock();
        roots.insert(Root(p));
        rootsLock.unlock();
    }


    /**
     *
     */
    void removeRoot(void *p) nothrow @nogc
    {
        rootsLock.lock();
        scope (failure) rootsLock.unlock();
        roots.remove(Root(p));
        rootsLock.unlock();
    }


    /**
     *
     */
    int rootsApply(scope int delegate(ref Root) nothrow dg) nothrow
    {
        rootsLock.lock();
        scope (failure) rootsLock.unlock();
        auto ret = roots.opApply(dg);
        rootsLock.unlock();
        return ret;
    }


    /**
     *
     */
    void addRange(void *pbot, void *ptop, const TypeInfo ti) nothrow @nogc
    {
        //debug(PRINTF) printf("Thread %x ", pthread_self());
        debug(PRINTF) printf("%p.Gcx::addRange(%p, %p)\n", &this, pbot, ptop);
        rangesLock.lock();
        scope (failure) rangesLock.unlock();
        ranges.insert(Range(pbot, ptop));
        rangesLock.unlock();
    }


    /**
     *
     */
    void removeRange(void *pbot) nothrow @nogc
    {
        //debug(PRINTF) printf("Thread %x ", pthread_self());
        debug(PRINTF) printf("Gcx.removeRange(%p)\n", pbot);
        rangesLock.lock();
        scope (failure) rangesLock.unlock();
        ranges.remove(Range(pbot, pbot)); // only pbot is used, see Range.opCmp
        rangesLock.unlock();

        // debug(PRINTF) printf("Wrong thread\n");
        // This is a fatal error, but ignore it.
        // The problem is that we can get a Close() call on a thread
        // other than the one the range was allocated on.
        //assert(zero);
    }

    /**
     *
     */
    int rangesApply(scope int delegate(ref Range) nothrow dg) nothrow
    {
        rangesLock.lock();
        scope (failure) rangesLock.unlock();
        auto ret = ranges.opApply(dg);
        rangesLock.unlock();
        return ret;
    }


    /**
     *
     */
    void runFinalizers(in void[] segment) nothrow
    {
        ConservativeGC._inFinalizer = true;
        scope (failure) ConservativeGC._inFinalizer = false;

        foreach (pool; pooltable[0 .. npools])
        {
            if (!pool.finals.nbits) continue;

            if (pool.isLargeObject)
            {
                auto lpool = cast(LargeObjectPool*) pool;
                lpool.runFinalizers(segment);
            }
            else
            {
                auto spool = cast(SmallObjectPool*) pool;
                spool.runFinalizers(segment);
            }
        }
        ConservativeGC._inFinalizer = false;
    }

    Pool* findPool(void* p) pure nothrow @nogc
    {
        return pooltable.findPool(p);
    }

    /**
     * Find base address of block containing pointer p.
     * Returns null if not a gc'd pointer
     */
    void* findBase(void *p) nothrow @nogc
    {
        Pool *pool;

        pool = findPool(p);
        if (pool)
            return pool.findBase(p);
        return null;
    }


    /**
     * Find size of pointer p.
     * Returns 0 if not a gc'd pointer
     */
    size_t findSize(void *p) nothrow @nogc
    {
        Pool* pool = findPool(p);
        if (pool)
            return pool.slGetSize(p);
        return 0;
    }

    /**
     *
     */
    BlkInfo getInfo(void* p) nothrow
    {
        Pool* pool = findPool(p);
        if (pool)
            return pool.slGetInfo(p);
        return BlkInfo();
    }

    /**
     * Computes the bin table using CTFE.
     */
    static byte[2049] ctfeBins() nothrow
    {
        byte[2049] ret;
        size_t p = 0;
        for (Bins b = B_16; b <= B_2048; b++)
            for ( ; p <= binsize[b]; p++)
                ret[p] = b;

        return ret;
    }

    static const byte[2049] binTable = ctfeBins();

    /**
     * Allocate a new pool of at least size bytes.
     * Sort it into pooltable[].
     * Mark all memory in the pool as B_FREE.
     * Return the actual number of bytes reserved or 0 on error.
     */
    size_t reserve(size_t size) nothrow
    {
        size_t npages = (size + PAGESIZE - 1) / PAGESIZE;

        // Assume reserve() is for small objects.
        Pool*  pool = newPool(npages, false);

        if (!pool)
            return 0;
        return pool.npages * PAGESIZE;
    }

    /**
     * Update the thresholds for when to collect the next time
     */
    void updateCollectThresholds() nothrow
    {
        static float max(float a, float b) nothrow
        {
            return a >= b ? a : b;
        }

        // instantly increases, slowly decreases
        static float smoothDecay(float oldVal, float newVal) nothrow
        {
            // decay to 63.2% of newVal over 5 collections
            // http://en.wikipedia.org/wiki/Low-pass_filter#Simple_infinite_impulse_response_filter
            enum alpha = 1.0 / (5 + 1);
            immutable decay = (newVal - oldVal) * alpha + oldVal;
            return max(newVal, decay);
        }

        immutable smTarget = usedSmallPages * config.heapSizeFactor;
        smallCollectThreshold = smoothDecay(smallCollectThreshold, smTarget);
        immutable lgTarget = usedLargePages * config.heapSizeFactor;
        largeCollectThreshold = smoothDecay(largeCollectThreshold, lgTarget);
    }

    /**
     * Minimizes physical memory usage by returning free pools to the OS.
     */
    void minimize() nothrow
    {
        debug(PRINTF) printf("Minimizing.\n");

        foreach (pool; pooltable.minimize())
        {
            debug(PRINTF) printFreeInfo(pool);
            mappedPages -= pool.npages;
            pool.Dtor();
            cstdlib.free(pool);
        }

        debug(PRINTF) printf("Done minimizing.\n");
    }

    private @property bool lowMem() const nothrow
    {
        return isLowOnMem(cast(size_t)mappedPages * PAGESIZE);
    }

    void* alloc(size_t size, ref size_t alloc_size, uint bits, const TypeInfo ti) nothrow
    {
        return size <= PAGESIZE/2 ? smallAlloc(size, alloc_size, bits, ti)
                                  : bigAlloc(size, alloc_size, bits, ti);
    }

    void* smallAlloc(size_t size, ref size_t alloc_size, uint bits, const TypeInfo ti) nothrow
    {
        immutable bin = binTable[size];
        alloc_size = binsize[bin];

        void* p = bucket[bin];
        if (p)
            goto L_hasBin;

        if (recoverPool[bin])
            recoverNextPage(bin);

        bool tryAlloc() nothrow
        {
            if (!bucket[bin])
            {
                bucket[bin] = allocPage(bin);
                if (!bucket[bin])
                    return false;
            }
            p = bucket[bin];
            return true;
        }

        if (!tryAlloc())
        {
            if (!lowMem && (disabled || usedSmallPages < smallCollectThreshold))
            {
                // disabled or threshold not reached => allocate a new pool instead of collecting
                if (!newPool(1, false))
                {
                    // out of memory => try to free some memory
                    fullcollect();
                    if (lowMem)
                        minimize();
                    recoverNextPage(bin);
                }
            }
            else
            {
                fullcollect();
                if (lowMem)
                    minimize();
                recoverNextPage(bin);
            }
            // tryAlloc will succeed if a new pool was allocated above, if it fails allocate a new pool now
            if (!tryAlloc() && (!newPool(1, false) || !tryAlloc()))
                // out of luck or memory
                onOutOfMemoryErrorNoGC();
        }
        assert(p !is null);
    L_hasBin:
        // Return next item from free list
        bucket[bin] = (cast(List*)p).next;
        auto pool = (cast(List*)p).pool;
        auto biti = (p - pool.baseAddr) >> pool.shiftBy;
        assert(pool.freebits.test(biti));
        pool.freebits.clear(biti);
        if (bits)
            pool.setBits(biti, bits);
        //debug(PRINTF) printf("\tmalloc => %p\n", p);
        debug (MEMSTOMP) memset(p, 0xF0, alloc_size);

        if (ConservativeGC.isPrecise)
        {
            debug(SENTINEL)
                pool.setPointerBitmapSmall(sentinel_add(p), size - SENTINEL_EXTRA, size - SENTINEL_EXTRA, bits, ti);
            else
                pool.setPointerBitmapSmall(p, size, alloc_size, bits, ti);
        }
        return p;
    }

    /**
     * Allocate a chunk of memory that is larger than a page.
     * Return null if out of memory.
     */
    void* bigAlloc(size_t size, ref size_t alloc_size, uint bits, const TypeInfo ti = null) nothrow
    {
        debug(PRINTF) printf("In bigAlloc.  Size:  %d\n", size);

        LargeObjectPool* pool;
        size_t pn;
        immutable npages = LargeObjectPool.numPages(size);
        if (npages == size_t.max)
            onOutOfMemoryErrorNoGC(); // size just below size_t.max requested

        bool tryAlloc() nothrow
        {
            foreach (p; pooltable[0 .. npools])
            {
                if (!p.isLargeObject || p.freepages < npages)
                    continue;
                auto lpool = cast(LargeObjectPool*) p;
                if ((pn = lpool.allocPages(npages)) == OPFAIL)
                    continue;
                pool = lpool;
                return true;
            }
            return false;
        }

        bool tryAllocNewPool() nothrow
        {
            pool = cast(LargeObjectPool*) newPool(npages, true);
            if (!pool) return false;
            pn = pool.allocPages(npages);
            assert(pn != OPFAIL);
            return true;
        }

        if (!tryAlloc())
        {
            if (!lowMem && (disabled || usedLargePages < largeCollectThreshold))
            {
                // disabled or threshold not reached => allocate a new pool instead of collecting
                if (!tryAllocNewPool())
                {
                    // disabled but out of memory => try to free some memory
                    fullcollect();
                    minimize();
                }
            }
            else
            {
                fullcollect();
                minimize();
            }
            // If alloc didn't yet succeed retry now that we collected/minimized
            if (!pool && !tryAlloc() && !tryAllocNewPool())
                // out of luck or memory
                return null;
        }
        assert(pool);

        debug(PRINTF) printFreeInfo(&pool.base);
        usedLargePages += npages;

        debug(PRINTF) printFreeInfo(&pool.base);

        auto p = pool.baseAddr + pn * PAGESIZE;
        debug(PRINTF) printf("Got large alloc:  %p, pt = %d, np = %d\n", p, pool.pagetable[pn], npages);
        debug (MEMSTOMP) memset(p, 0xF1, size);
        alloc_size = npages * PAGESIZE;
        //debug(PRINTF) printf("\tp = %p\n", p);

        if (bits)
            pool.setBits(pn, bits);

        if (ConservativeGC.isPrecise)
        {
            // an array of classes is in fact an array of pointers
            immutable(void)* rtinfo;
            if (!ti)
                rtinfo = rtinfoHasPointers;
            else if ((bits & BlkAttr.APPENDABLE) && (typeid(ti) is typeid(TypeInfo_Class)))
                rtinfo = rtinfoHasPointers;
            else
                rtinfo = ti.rtInfo();
            pool.rtinfo[pn] = cast(immutable(size_t)*)rtinfo;
        }

        return p;
    }


    /**
     * Allocate a new pool with at least npages in it.
     * Sort it into pooltable[].
     * Return null if failed.
     */
    Pool *newPool(size_t npages, bool isLargeObject) nothrow
    {
        //debug(PRINTF) printf("************Gcx::newPool(npages = %d)****************\n", npages);

        // Minimum of POOLSIZE
        size_t minPages = (config.minPoolSize << 20) / PAGESIZE;
        if (npages < minPages)
            npages = minPages;
        else if (npages > minPages)
        {   // Give us 150% of requested size, so there's room to extend
            auto n = npages + (npages >> 1);
            if (n < size_t.max/PAGESIZE)
                npages = n;
        }

        // Allocate successively larger pools up to 8 megs
        if (npools)
        {   size_t n;

            n = config.minPoolSize + config.incPoolSize * npools;
            if (n > config.maxPoolSize)
                n = config.maxPoolSize;                 // cap pool size
            n *= (1 << 20) / PAGESIZE;                     // convert MB to pages
            if (npages < n)
                npages = n;
        }

        //printf("npages = %d\n", npages);

        auto pool = cast(Pool *)cstdlib.calloc(1, isLargeObject ? LargeObjectPool.sizeof : SmallObjectPool.sizeof);
        if (pool)
        {
            pool.initialize(npages, isLargeObject);
            if (!pool.baseAddr || !pooltable.insert(pool))
            {
                pool.Dtor();
                cstdlib.free(pool);
                return null;
            }
        }

        mappedPages += npages;

        if (config.profile)
        {
            if (cast(size_t)mappedPages * PAGESIZE > maxPoolMemory)
                maxPoolMemory = cast(size_t)mappedPages * PAGESIZE;
        }
        return pool;
    }

    /**
    * Allocate a page of bin's.
    * Returns:
    *           head of a single linked list of new entries
    */
    List* allocPage(Bins bin) nothrow
    {
        //debug(PRINTF) printf("Gcx::allocPage(bin = %d)\n", bin);
        for (size_t n = 0; n < npools; n++)
        {
            Pool* pool = pooltable[n];
            if (pool.isLargeObject)
                continue;
            if (List* p = (cast(SmallObjectPool*)pool).allocPage(bin))
            {
                ++usedSmallPages;
                return p;
            }
        }
        return null;
    }

    static struct ScanRange(bool precise)
    {
        void* pbot;
        void* ptop;
        static if (precise)
        {
            void** pbase;      // start of memory described by ptrbitmap
            size_t* ptrbmp;    // bits from is_pointer or rtinfo
            size_t bmplength;  // number of valid bits
        }
    }

    static struct ToScanStack(RANGE)
    {
    nothrow:
        @disable this(this);
        auto stackLock = shared(AlignedSpinLock)(SpinLock.Contention.brief);

        void reset()
        {
            _length = 0;
            if (_p)
            {
                os_mem_unmap(_p, _cap * RANGE.sizeof);
                _p = null;
            }
            _cap = 0;
        }
        void clear()
        {
            _length = 0;
        }

        void push(RANGE rng)
        {
            if (_length == _cap) grow();
            _p[_length++] = rng;
        }

        RANGE pop()
        in { assert(!empty); }
        do
        {
            return _p[--_length];
        }

        bool popLocked(ref RANGE rng)
        {
            if (_length == 0)
                return false;

            stackLock.lock();
            scope(exit) stackLock.unlock();
            if (_length == 0)
                return false;
            rng = _p[--_length];
            return true;
        }

        ref inout(RANGE) opIndex(size_t idx) inout
        in { assert(idx < _length); }
        do
        {
            return _p[idx];
        }

        @property size_t length() const { return _length; }
        @property bool empty() const { return !length; }

    private:
        void grow()
        {
            pragma(inline, false);

            enum initSize = 64 * 1024; // Windows VirtualAlloc granularity
            immutable ncap = _cap ? 2 * _cap : initSize / RANGE.sizeof;
            auto p = cast(RANGE*)os_mem_map(ncap * RANGE.sizeof);
            if (p is null) onOutOfMemoryErrorNoGC();
            if (_p !is null)
            {
                p[0 .. _length] = _p[0 .. _length];
                os_mem_unmap(_p, _cap * RANGE.sizeof);
            }
            _p = p;
            _cap = ncap;
        }

        size_t _length;
        RANGE* _p;
        size_t _cap;
    }

    ToScanStack!(ScanRange!false) toscanConservative;
    ToScanStack!(ScanRange!true) toscanPrecise;

    template scanStack(bool precise)
    {
        static if (precise)
            alias scanStack = toscanPrecise;
        else
            alias scanStack = toscanConservative;
    }

    /**
     * Search a range of memory values and mark any pointers into the GC pool.
     */
    private void mark(bool precise, bool parallel)(ScanRange!precise rng) scope nothrow
    {
        alias toscan = scanStack!precise;

        debug(MARK_PRINTF)
            printf("marking range: [%p..%p] (%#llx)\n", pbot, ptop, cast(long)(ptop - pbot));

        // limit the amount of ranges added to the toscan stack
        enum FANOUT_LIMIT = 32;
        size_t stackPos;
        ScanRange!precise[FANOUT_LIMIT] stack = void;

        size_t pcache = 0;

        // let dmd allocate a register for this.pools
        auto pools = pooltable.pools;
        const highpool = pooltable.npools - 1;
        const minAddr = pooltable.minAddr;
        size_t memSize = pooltable.maxAddr - minAddr;
        Pool* pool = null;

        // properties of allocation pointed to
        ScanRange!precise tgt = void;

        for (;;)
        {
            auto p = *cast(void**)(rng.pbot);

            debug(MARK_PRINTF) printf("\tmark %p: %p\n", rng.pbot, p);

            if (cast(size_t)(p - minAddr) < memSize &&
                (cast(size_t)p & ~cast(size_t)(PAGESIZE-1)) != pcache)
            {
                static if (precise) if (rng.pbase)
                {
                    size_t bitpos = cast(void**)rng.pbot - rng.pbase;
                    while (bitpos >= rng.bmplength)
                    {
                        bitpos -= rng.bmplength;
                        rng.pbase += rng.bmplength;
                    }
                    import core.bitop;
                    if (!core.bitop.bt(rng.ptrbmp, bitpos))
                    {
                        debug(MARK_PRINTF) printf("\t\tskipping non-pointer\n");
                        goto LnextPtr;
                    }
                }

                if (!pool || p < pool.baseAddr || p >= pool.topAddr)
                {
                    size_t low = 0;
                    size_t high = highpool;
                    while (true)
                    {
                        size_t mid = (low + high) >> 1;
                        pool = pools[mid];
                        if (p < pool.baseAddr)
                            high = mid - 1;
                        else if (p >= pool.topAddr)
                            low = mid + 1;
                        else break;

                        if (low > high)
                            goto LnextPtr;
                    }
                }
                size_t offset = cast(size_t)(p - pool.baseAddr);
                size_t biti = void;
                size_t pn = offset / PAGESIZE;
                size_t bin = pool.pagetable[pn]; // not Bins to avoid multiple size extension instructions

                debug(MARK_PRINTF)
                    printf("\t\tfound pool %p, base=%p, pn = %lld, bin = %d\n", pool, pool.baseAddr, cast(long)pn, bin);

                // Adjust bit to be at start of allocated memory block
                if (bin < B_PAGE)
                {
                    // We don't care abou setting pointsToBase correctly
                    // because it's ignored for small object pools anyhow.
                    auto offsetBase = baseOffset(offset, cast(Bins)bin);
                    biti = offsetBase >> Pool.ShiftBy.Small;
                    //debug(PRINTF) printf("\t\tbiti = x%x\n", biti);

                    if (!pool.mark.testAndSet!parallel(biti) && !pool.noscan.test(biti))
                    {
                        tgt.pbot = pool.baseAddr + offsetBase;
                        tgt.ptop = tgt.pbot + binsize[bin];
                        static if (precise)
                        {
                            tgt.pbase = cast(void**)pool.baseAddr;
                            tgt.ptrbmp = pool.is_pointer.data;
                            tgt.bmplength = size_t.max; // no repetition
                        }
                        goto LaddRange;
                    }
                }
                else if (bin == B_PAGE)
                {
                    biti = offset >> Pool.ShiftBy.Large;
                    //debug(PRINTF) printf("\t\tbiti = x%x\n", biti);

                    pcache = cast(size_t)p & ~cast(size_t)(PAGESIZE-1);
                    tgt.pbot = cast(void*)pcache;

                    // For the NO_INTERIOR attribute.  This tracks whether
                    // the pointer is an interior pointer or points to the
                    // base address of a block.
                    if (tgt.pbot != sentinel_sub(p) && pool.nointerior.nbits && pool.nointerior.test(biti))
                        goto LnextPtr;

                    if (!pool.mark.testAndSet!parallel(biti) && !pool.noscan.test(biti))
                    {
                        tgt.ptop = tgt.pbot + (cast(LargeObjectPool*)pool).getSize(pn);
                        goto LaddLargeRange;
                    }
                }
                else if (bin == B_PAGEPLUS)
                {
                    pn -= pool.bPageOffsets[pn];
                    biti = pn * (PAGESIZE >> Pool.ShiftBy.Large);

                    pcache = cast(size_t)p & ~cast(size_t)(PAGESIZE-1);
                    if (pool.nointerior.nbits && pool.nointerior.test(biti))
                        goto LnextPtr;

                    if (!pool.mark.testAndSet!parallel(biti) && !pool.noscan.test(biti))
                    {
                        tgt.pbot = pool.baseAddr + (pn * PAGESIZE);
                        tgt.ptop = tgt.pbot + (cast(LargeObjectPool*)pool).getSize(pn);
                    LaddLargeRange:
                        static if (precise)
                        {
                            auto rtinfo = pool.rtinfo[biti];
                            if (rtinfo is rtinfoNoPointers)
                                goto LnextPtr; // only if inconsistent with noscan
                            if (rtinfo is rtinfoHasPointers)
                            {
                                tgt.pbase = null; // conservative
                            }
                            else
                            {
                                tgt.ptrbmp = cast(size_t*)rtinfo;
                                size_t element_size = *tgt.ptrbmp++;
                                tgt.bmplength = (element_size + (void*).sizeof - 1) / (void*).sizeof;
                                assert(tgt.bmplength);

                                debug(SENTINEL)
                                    tgt.pbot = sentinel_add(tgt.pbot);
                                if (pool.appendable.test(biti))
                                {
                                    // take advantage of knowing array layout in rt.lifetime
                                    void* arrtop = tgt.pbot + 16 + *cast(size_t*)tgt.pbot;
                                    assert (arrtop > tgt.pbot && arrtop <= tgt.ptop);
                                    tgt.pbot += 16;
                                    tgt.ptop = arrtop;
                                }
                                else
                                {
                                    tgt.ptop = tgt.pbot + element_size;
                                }
                                tgt.pbase = cast(void**)tgt.pbot;
                            }
                        }
                        goto LaddRange;
                    }
                }
                else
                {
                    // Don't mark bits in B_FREE pages
                    assert(bin == B_FREE);
                }
            }
        LnextPtr:
            rng.pbot += (void*).sizeof;
            if (rng.pbot < rng.ptop)
                continue;

        LnextRange:
            if (stackPos)
            {
                // pop range from local stack and recurse
                rng = stack[--stackPos];
            }
            else
            {
                static if (parallel)
                {
                    if (!toscan.popLocked(rng))
                        break; // nothing more to do
                }
                else
                {
                    if (toscan.empty)
                        break; // nothing more to do

                    // pop range from global stack and recurse
                    rng = toscan.pop();
                }
            }
            // printf("  pop [%p..%p] (%#zx)\n", p1, p2, cast(size_t)p2 - cast(size_t)p1);
            goto LcontRange;

        LaddRange:
            rng.pbot += (void*).sizeof;
            if (rng.pbot < rng.ptop)
            {
                if (stackPos < stack.length)
                {
                    stack[stackPos] = tgt;
                    stackPos++;
                    continue;
                }
                static if (parallel)
                {
                    toscan.stackLock.lock();
                    scope(exit) toscan.stackLock.unlock();
                }
                toscan.push(rng);
                // reverse order for depth-first-order traversal
                foreach_reverse (ref range; stack)
                    toscan.push(range);
                stackPos = 0;
            }
        LendOfRange:
            // continue with last found range
            rng = tgt;

        LcontRange:
            pcache = 0;
        }
    }

    void markConservative(void *pbot, void *ptop) scope nothrow
    {
        if (pbot < ptop)
            mark!(false, false)(ScanRange!false(pbot, ptop));
    }

    void markPrecise(void *pbot, void *ptop) scope nothrow
    {
        if (pbot < ptop)
            mark!(true, false)(ScanRange!true(pbot, ptop, null));
    }

    version (COLLECT_PARALLEL)
    ToScanStack!(void*) toscanRoots;

    version (COLLECT_PARALLEL)
    void collectRoots(void *pbot, void *ptop) scope nothrow
    {
        const minAddr = pooltable.minAddr;
        size_t memSize = pooltable.maxAddr - minAddr;

        for (auto p = cast(void**)pbot; cast(void*)p < ptop; p++)
        {
            auto ptr = *p;
            if (cast(size_t)(ptr - minAddr) < memSize)
                toscanRoots.push(ptr);
        }
    }

    // collection step 1: prepare freebits and mark bits
    void prepare() nothrow
    {
        debug(COLLECT_PRINTF) printf("preparing mark.\n");

        for (size_t n = 0; n < npools; n++)
        {
            Pool* pool = pooltable[n];
            if (pool.isLargeObject)
                pool.mark.zero();
            else
                pool.mark.copy(&pool.freebits);
        }
    }

    // collection step 2: mark roots and heap
    void markAll(alias markFn)(bool nostack) nothrow
    {
        if (!nostack)
        {
            debug(COLLECT_PRINTF) printf("\tscan stacks.\n");
            // Scan stacks and registers for each paused thread
            thread_scanAll(&markFn);
        }

        // Scan roots[]
        debug(COLLECT_PRINTF) printf("\tscan roots[]\n");
        foreach (root; roots)
        {
            markFn(cast(void*)&root.proot, cast(void*)(&root.proot + 1));
        }

        // Scan ranges[]
        debug(COLLECT_PRINTF) printf("\tscan ranges[]\n");
        //log++;
        foreach (range; ranges)
        {
            debug(COLLECT_PRINTF) printf("\t\t%p .. %p\n", range.pbot, range.ptop);
            markFn(range.pbot, range.ptop);
        }
        //log--;
    }

    version (COLLECT_PARALLEL)
    void collectAllRoots(bool nostack) nothrow
    {
        if (!nostack)
        {
            debug(COLLECT_PRINTF) printf("\tcollect stacks.\n");
            // Scan stacks and registers for each paused thread
            thread_scanAll(&collectRoots);
        }

        // Scan roots[]
        debug(COLLECT_PRINTF) printf("\tcollect roots[]\n");
        foreach (root; roots)
        {
            toscanRoots.push(root);
        }

        // Scan ranges[]
        debug(COLLECT_PRINTF) printf("\tcollect ranges[]\n");
        foreach (range; ranges)
        {
            debug(COLLECT_PRINTF) printf("\t\t%p .. %p\n", range.pbot, range.ptop);
            collectRoots(range.pbot, range.ptop);
        }
    }

    // collection step 3: finalize unreferenced objects, recover full pages with no live objects
    size_t sweep() nothrow
    {
        // Free up everything not marked
        debug(COLLECT_PRINTF) printf("\tfree'ing\n");
        size_t freedLargePages;
        size_t freedSmallPages;
        size_t freed;
        for (size_t n = 0; n < npools; n++)
        {
            size_t pn;
            Pool* pool = pooltable[n];

            if (pool.isLargeObject)
            {
                auto lpool = cast(LargeObjectPool*)pool;
                size_t numFree = 0;
                size_t npages;
                for (pn = 0; pn < pool.npages; pn += npages)
                {
                    npages = pool.bPageOffsets[pn];
                    Bins bin = cast(Bins)pool.pagetable[pn];
                    if (bin == B_FREE)
                    {
                        numFree += npages;
                        continue;
                    }
                    assert(bin == B_PAGE);
                    size_t biti = pn;

                    if (!pool.mark.test(biti))
                    {
                        void *p = pool.baseAddr + pn * PAGESIZE;
                        void* q = sentinel_add(p);
                        sentinel_Invariant(q);

                        if (pool.finals.nbits && pool.finals.clear(biti))
                        {
                            size_t size = npages * PAGESIZE - SENTINEL_EXTRA;
                            uint attr = pool.getBits(biti);
                            rt_finalizeFromGC(q, sentinel_size(q, size), attr);
                        }

                        pool.clrBits(biti, ~BlkAttr.NONE ^ BlkAttr.FINALIZE);

                        debug(COLLECT_PRINTF) printf("\tcollecting big %p\n", p);
                        leakDetector.log_free(q);
                        pool.pagetable[pn..pn+npages] = B_FREE;
                        if (pn < pool.searchStart) pool.searchStart = pn;
                        freedLargePages += npages;
                        pool.freepages += npages;
                        numFree += npages;

                        debug (MEMSTOMP) memset(p, 0xF3, npages * PAGESIZE);
                        // Don't need to update searchStart here because
                        // pn is guaranteed to be greater than last time
                        // we updated it.

                        pool.largestFree = pool.freepages; // invalidate
                    }
                    else
                    {
                        if (numFree > 0)
                        {
                            lpool.setFreePageOffsets(pn - numFree, numFree);
                            numFree = 0;
                        }
                    }
                }
                if (numFree > 0)
                    lpool.setFreePageOffsets(pn - numFree, numFree);
            }
            else
            {
                // reinit chain of pages to rebuild free list
                pool.recoverPageFirst[] = cast(uint)pool.npages;

                for (pn = 0; pn < pool.npages; pn++)
                {
                    Bins bin = cast(Bins)pool.pagetable[pn];

                    if (bin < B_PAGE)
                    {
                        auto freebitsdata = pool.freebits.data + pn * PageBits.length;
                        auto markdata = pool.mark.data + pn * PageBits.length;

                        // the entries to free are allocated objects (freebits == false)
                        // that are not marked (mark == false)
                        PageBits toFree;
                        static foreach (w; 0 .. PageBits.length)
                            toFree[w] = (~freebitsdata[w] & ~markdata[w]);

                        // the page is unchanged if there is nothing to free
                        bool unchanged = true;
                        static foreach (w; 0 .. PageBits.length)
                            unchanged = unchanged && (toFree[w] == 0);
                        if (unchanged)
                        {
                            bool hasDead = false;
                            static foreach (w; 0 .. PageBits.length)
                                hasDead = hasDead && (~freebitsdata[w] != baseOffsetBits[bin][w]);
                            if (hasDead)
                            {
                                // add to recover chain
                                pool.binPageChain[pn] = pool.recoverPageFirst[bin];
                                pool.recoverPageFirst[bin] = cast(uint)pn;
                            }
                            else
                            {
                                pool.binPageChain[pn] = Pool.PageRecovered;
                            }
                            continue;
                        }

                        // the page can be recovered if all of the allocated objects (freebits == false)
                        // are freed
                        bool recoverPage = true;
                        static foreach (w; 0 .. PageBits.length)
                            recoverPage = recoverPage && (~freebitsdata[w] == toFree[w]);

                        bool hasFinalizer = false;
                        debug(COLLECT_PRINTF) // need output for each onject
                            hasFinalizer = true;
                        else debug(LOGGING)
                            hasFinalizer = true;
                        else debug(MEMSTOMP)
                            hasFinalizer = true;
                        if (pool.finals.data)
                        {
                            // finalizers must be called on objects that are about to be freed
                            auto finalsdata = pool.finals.data + pn * PageBits.length;
                            static foreach (w; 0 .. PageBits.length)
                                hasFinalizer = hasFinalizer || (toFree[w] & finalsdata[w]) != 0;
                        }

                        if (hasFinalizer)
                        {
                            immutable size = binsize[bin];
                            void *p = pool.baseAddr + pn * PAGESIZE;
                            immutable base = pn * (PAGESIZE/16);
                            immutable bitstride = size / 16;

                            // ensure that there are at least <size> bytes for every address
                            //  below ptop even if unaligned
                            void *ptop = p + PAGESIZE - size + 1;
                            for (size_t i; p < ptop; p += size, i += bitstride)
                            {
                                immutable biti = base + i;

                                if (!pool.mark.test(biti))
                                {
                                    void* q = sentinel_add(p);
                                    sentinel_Invariant(q);

                                    if (pool.finals.nbits && pool.finals.test(biti))
                                        rt_finalizeFromGC(q, sentinel_size(q, size), pool.getBits(biti));

                                    assert(core.bitop.bt(toFree.ptr, i));

                                    debug(COLLECT_PRINTF) printf("\tcollecting %p\n", p);
                                    leakDetector.log_free(sentinel_add(p));

                                    debug (MEMSTOMP) memset(p, 0xF3, size);
                                }
                            }
                        }

                        if (recoverPage)
                        {
                            pool.freeAllPageBits(pn);

                            pool.pagetable[pn] = B_FREE;
                            // add to free chain
                            pool.binPageChain[pn] = cast(uint) pool.searchStart;
                            pool.searchStart = pn;
                            pool.freepages++;
                            freedSmallPages++;
                        }
                        else
                        {
                            pool.freePageBits(pn, toFree);

                            // add to recover chain
                            pool.binPageChain[pn] = pool.recoverPageFirst[bin];
                            pool.recoverPageFirst[bin] = cast(uint)pn;
                        }
                    }
                }
            }
        }

        assert(freedLargePages <= usedLargePages);
        usedLargePages -= freedLargePages;
        debug(COLLECT_PRINTF) printf("\tfree'd %u bytes, %u pages from %u pools\n", freed, freedLargePages, npools);

        assert(freedSmallPages <= usedSmallPages);
        usedSmallPages -= freedSmallPages;
        debug(COLLECT_PRINTF) printf("\trecovered small pages = %d\n", freedSmallPages);

        return freedLargePages + freedSmallPages;
    }

    bool recoverPage(SmallObjectPool* pool, size_t pn, Bins bin) nothrow
    {
        size_t size = binsize[bin];
        size_t bitbase = pn * (PAGESIZE / 16);

        auto freebitsdata = pool.freebits.data + pn * PageBits.length;

        // the page had dead objects when collecting, these cannot have been resurrected
        bool hasDead = false;
        static foreach (w; 0 .. PageBits.length)
            hasDead = hasDead || (freebitsdata[w] != 0);
        assert(hasDead);

        // prepend to buckets, but with forward addresses inside the page
        assert(bucket[bin] is null);
        List** bucketTail = &bucket[bin];

        void* p = pool.baseAddr + pn * PAGESIZE;
        const top = PAGESIZE - size + 1; // ensure <size> bytes available even if unaligned
        for (size_t u = 0; u < top; u += size)
        {
            if (!core.bitop.bt(freebitsdata, u / 16))
                continue;
            auto elem = cast(List *)(p + u);
            elem.pool = &pool.base;
            *bucketTail = elem;
            bucketTail = &elem.next;
        }
        *bucketTail = null;
        assert(bucket[bin] !is null);
        return true;
    }

    bool recoverNextPage(Bins bin) nothrow
    {
        SmallObjectPool* pool = recoverPool[bin];
        while (pool)
        {
            auto pn = pool.recoverPageFirst[bin];
            while (pn < pool.npages)
            {
                auto next = pool.binPageChain[pn];
                pool.binPageChain[pn] = Pool.PageRecovered;
                pool.recoverPageFirst[bin] = next;
                if (recoverPage(pool, pn, bin))
                    return true;
                pn = next;
            }
            pool = setNextRecoverPool(bin, pool.ptIndex + 1);
        }
        return false;
    }

    private SmallObjectPool* setNextRecoverPool(Bins bin, size_t poolIndex) nothrow
    {
        Pool* pool;
        while (poolIndex < npools &&
               ((pool = pooltable[poolIndex]).isLargeObject ||
                pool.recoverPageFirst[bin] >= pool.npages))
            poolIndex++;

        return recoverPool[bin] = poolIndex < npools ? cast(SmallObjectPool*)pool : null;
    }


    /**
     * Return number of full pages free'd.
     */
    size_t fullcollect(bool nostack = false) nothrow
    {
        // It is possible that `fullcollect` will be called from a thread which
        // is not yet registered in runtime (because allocating `new Thread` is
        // part of `thread_attachThis` implementation). In that case it is
        // better not to try actually collecting anything

        if (Thread.getThis() is null)
            return 0;

        MonoTime start, stop, begin;
        begin = start = currTime;

        debug(COLLECT_PRINTF) printf("Gcx.fullcollect()\n");
        //printf("\tpool address range = %p .. %p\n", minAddr, maxAddr);

        {
            // lock roots and ranges around suspending threads b/c they're not reentrant safe
            rangesLock.lock();
            rootsLock.lock();
            debug(INVARIANT) inCollection = true;
            scope (exit)
            {
                debug(INVARIANT) inCollection = false;
                rangesLock.unlock();
                rootsLock.unlock();
            }
            thread_suspendAll();

            prepare();

            stop = currTime;
            prepTime += (stop - start);
            start = stop;

            version (COLLECT_PARALLEL)
                bool doParallel = config.parallel > 0;
            else
                enum doParallel = false;

            if (doParallel)
            {
                version (COLLECT_PARALLEL)
                    markParallel(nostack);
            }
            else
            {
                if (ConservativeGC.isPrecise)
                    markAll!markPrecise(nostack);
                else
                    markAll!markConservative(nostack);
            }

            thread_processGCMarks(&isMarked);
            thread_resumeAll();
        }

        stop = currTime;
        markTime += (stop - start);
        Duration pause = stop - begin;
        if (pause > maxPauseTime)
            maxPauseTime = pause;
        pauseTime += pause;
        start = stop;

        ConservativeGC._inFinalizer = true;
        size_t freedPages = void;
        {
            scope (failure) ConservativeGC._inFinalizer = false;
            freedPages = sweep();
            ConservativeGC._inFinalizer = false;
        }

        // init bucket lists
        bucket[] = null;
        foreach (Bins bin; 0..B_NUMSMALL)
            setNextRecoverPool(bin, 0);

        stop = currTime;
        sweepTime += (stop - start);

        Duration collectionTime = stop - begin;
        if (collectionTime > maxCollectionTime)
            maxCollectionTime = collectionTime;

        ++numCollections;

        updateCollectThresholds();

        return freedPages;
    }

    /**
     * Returns true if the addr lies within a marked block.
     *
     * Warning! This should only be called while the world is stopped inside
     * the fullcollect function after all live objects have been marked, but before sweeping.
     */
    int isMarked(void *addr) scope nothrow
    {
        // first, we find the Pool this block is in, then check to see if the
        // mark bit is clear.
        auto pool = findPool(addr);
        if (pool)
        {
            auto offset = cast(size_t)(addr - pool.baseAddr);
            auto pn = offset / PAGESIZE;
            auto bins = cast(Bins)pool.pagetable[pn];
            size_t biti = void;
            if (bins < B_PAGE)
            {
                biti = baseOffset(offset, bins) >> pool.ShiftBy.Small;
                // doesn't need to check freebits because no pointer must exist
                //  to a block that was free before starting the collection
            }
            else if (bins == B_PAGE)
            {
                biti = pn * (PAGESIZE >> pool.ShiftBy.Large);
            }
            else if (bins == B_PAGEPLUS)
            {
                pn -= pool.bPageOffsets[pn];
                biti = pn * (PAGESIZE >> pool.ShiftBy.Large);
            }
            else // bins == B_FREE
            {
                assert(bins == B_FREE);
                return IsMarked.no;
            }
            return pool.mark.test(biti) ? IsMarked.yes : IsMarked.no;
        }
        return IsMarked.unknown;
    }

    /* ============================ Parallel scanning =============================== */
    version (COLLECT_PARALLEL):
    import core.sync.event;
    import core.atomic;
    private: // disable invariants for background threads

    static struct ScanThreadData
    {
        ThreadID tid;
    }
    uint numScanThreads;
    ScanThreadData* scanThreadData;

    Event evStart;
    Event evDone;

    shared uint busyThreads;
    bool stopGC;

    void markParallel(bool nostack) nothrow
    {
        toscanRoots.clear();
        collectAllRoots(nostack);
        if (toscanRoots.empty)
            return;

        void** pbot = toscanRoots._p;
        void** ptop = toscanRoots._p + toscanRoots._length;

        if (!scanThreadData)
            startScanThreads();

        debug(PARALLEL_PRINTF) printf("markParallel\n");

        size_t pointersPerThread = toscanRoots._length / (numScanThreads + 1);
        if (pointersPerThread > 0)
        {
            void pushRanges(bool precise)()
            {
                alias toscan = scanStack!precise;
                toscan.stackLock.lock();

                for (int idx = 0; idx < numScanThreads; idx++)
                {
                    toscan.push(ScanRange!precise(pbot, pbot + pointersPerThread));
                    pbot += pointersPerThread;
                }
                toscan.stackLock.unlock();
            }
            if (ConservativeGC.isPrecise)
                pushRanges!true();
            else
                pushRanges!false();
        }
        assert(pbot < ptop);

        busyThreads.atomicOp!"+="(1); // main thread is busy

        evStart.set();

        debug(PARALLEL_PRINTF) printf("mark %lld roots\n", cast(ulong)(ptop - pbot));

        if (ConservativeGC.isPrecise)
            mark!(true, true)(ScanRange!true(pbot, ptop, null));
        else
            mark!(false, true)(ScanRange!false(pbot, ptop));

        busyThreads.atomicOp!"-="(1);

        debug(PARALLEL_PRINTF) printf("waitForScanDone\n");
        pullFromScanStack();
        debug(PARALLEL_PRINTF) printf("waitForScanDone done\n");
    }

    int maxParallelThreads() nothrow
    {
        import core.cpuid;
        auto threads = threadsPerCPU();

        if (threads == 0)
        {
            // If the GC is called by module ctors no explicit
            // import dependency on the GC is generated. So the
            // GC module is not correctly inserted into the module
            // initialization chain. As it relies on core.cpuid being
            // initialized, force this here.
            try
            {
                foreach (m; ModuleInfo)
                    if (m.name == "core.cpuid")
                        if (auto ctor = m.ctor())
                        {
                            ctor();
                            threads = threadsPerCPU();
                            break;
                        }
            }
            catch (Exception)
            {
                assert(false, "unexpected exception iterating ModuleInfo");
            }
        }
        return threads;
    }


    void startScanThreads() nothrow
    {
        auto threads = maxParallelThreads();
        debug(PARALLEL_PRINTF) printf("startScanThreads: %d threads per CPU\n", threads);
        if (threads <= 1)
            return; // either core.cpuid not initialized or single core

        numScanThreads = threads >= config.parallel ? config.parallel : threads - 1;

        scanThreadData = cast(ScanThreadData*) cstdlib.calloc(numScanThreads, ScanThreadData.sizeof);
        if (!scanThreadData)
            onOutOfMemoryErrorNoGC();

        evStart.initialize(false, false);
        evDone.initialize(false, false);

        for (int idx = 0; idx < numScanThreads; idx++)
            scanThreadData[idx].tid = createLowLevelThread(&scanBackground, 0x4000, &stopScanThreads);
    }

    void stopScanThreads() nothrow
    {
        if (!numScanThreads)
            return;

        debug(PARALLEL_PRINTF) printf("stopScanThreads\n");
        stopGC = true;
        evStart.set();

        for (int idx = 0; idx < numScanThreads; idx++)
        {
            if (scanThreadData[idx].tid != scanThreadData[idx].tid.init)
            {
                joinLowLevelThread(scanThreadData[idx].tid);
                scanThreadData[idx].tid = scanThreadData[idx].tid.init;
            }
        }

        evDone.terminate();
        evStart.terminate();

        cstdlib.free(scanThreadData);
        // scanThreadData = null; // keep non-null to not start again after shutdown
        numScanThreads = 0;

        debug(PARALLEL_PRINTF) printf("stopScanThreads done\n");
    }

    void scanBackground() nothrow
    {
        while (!stopGC)
        {
            evStart.wait(dur!"msecs"(10));
            pullFromScanStack();
            evDone.set();
        }
    }

    void pullFromScanStack() nothrow
    {
        if (ConservativeGC.isPrecise)
            pullFromScanStackImpl!true();
        else
            pullFromScanStackImpl!false();
    }

    void pullFromScanStackImpl(bool precise)() nothrow
    {
        if (atomicLoad(busyThreads) == 0)
            return;

        debug(PARALLEL_PRINTF)
            pthread_t threadId = pthread_self();
        debug(PARALLEL_PRINTF) printf("scanBackground thread %d start\n", threadId);

        ScanRange!precise rng;
        alias toscan = scanStack!precise;

        while (atomicLoad(busyThreads) > 0)
        {
            if (toscan.empty)
            {
                evDone.wait(dur!"msecs"(1));
                continue;
            }

            busyThreads.atomicOp!"+="(1);
            if (toscan.popLocked(rng))
            {
                debug(PARALLEL_PRINTF) printf("scanBackground thread %d scanning range [%p,%lld] from stack\n", threadId,
                                              rng.pbot, cast(long) (rng.ptop - rng.pbot));
                mark!(precise, true)(rng);
            }
            busyThreads.atomicOp!"-="(1);
        }
        debug(PARALLEL_PRINTF) printf("scanBackground thread %d done\n", threadId);
    }
}

/* ============================ Pool  =============================== */

struct Pool
{
    void* baseAddr;
    void* topAddr;
    size_t ptIndex;     // index in pool table
    GCBits mark;        // entries already scanned, or should not be scanned
    GCBits freebits;    // entries that are on the free list (all bits set but for allocated objects at their base offset)
    GCBits finals;      // entries that need finalizer run on them
    GCBits structFinals;// struct entries that need a finalzier run on them
    GCBits noscan;      // entries that should not be scanned
    GCBits appendable;  // entries that are appendable
    GCBits nointerior;  // interior pointers should be ignored.
                        // Only implemented for large object pools.
    GCBits is_pointer;  // precise GC only: per-word, not per-block like the rest of them (SmallObjectPool only)
    size_t npages;
    size_t freepages;     // The number of pages not in use.
    ubyte* pagetable;

    bool isLargeObject;

    enum ShiftBy
    {
        Small = 4,
        Large = 12
    }
    ShiftBy shiftBy;    // shift count for the divisor used for determining bit indices.

    // This tracks how far back we have to go to find the nearest B_PAGE at
    // a smaller address than a B_PAGEPLUS.  To save space, we use a uint.
    // This limits individual allocations to 16 terabytes, assuming a 4k
    // pagesize. (LargeObjectPool only)
    // For B_PAGE and B_FREE, this specifies the number of pages in this block.
    // As an optimization, a contiguous range of free pages tracks this information
    //  only for the first and the last page.
    uint* bPageOffsets;

    // The small object pool uses the same array to keep a chain of
    // - pages with the same bin size that are still to be recovered
    // - free pages (searchStart is first free page)
    // other pages are marked by value PageRecovered
    alias binPageChain = bPageOffsets;

    enum PageRecovered = uint.max;

    // first of chain of pages to recover (SmallObjectPool only)
    uint[B_NUMSMALL] recoverPageFirst;

    // precise GC: TypeInfo.rtInfo for allocation (LargeObjectPool only)
    immutable(size_t)** rtinfo;

    // This variable tracks a conservative estimate of where the first free
    // page in this pool is, so that if a lot of pages towards the beginning
    // are occupied, we can bypass them in O(1).
    size_t searchStart;
    size_t largestFree; // upper limit for largest free chunk in large object pool

    void initialize(size_t npages, bool isLargeObject) nothrow
    {
        this.isLargeObject = isLargeObject;
        size_t poolsize;

        shiftBy = isLargeObject ? ShiftBy.Large : ShiftBy.Small;

        //debug(PRINTF) printf("Pool::Pool(%u)\n", npages);
        poolsize = npages * PAGESIZE;
        assert(poolsize >= POOLSIZE);
        baseAddr = cast(byte *)os_mem_map(poolsize);

        // Some of the code depends on page alignment of memory pools
        assert((cast(size_t)baseAddr & (PAGESIZE - 1)) == 0);

        if (!baseAddr)
        {
            //debug(PRINTF) printf("GC fail: poolsize = x%zx, errno = %d\n", poolsize, errno);
            //debug(PRINTF) printf("message = '%s'\n", sys_errlist[errno]);

            npages = 0;
            poolsize = 0;
        }
        //assert(baseAddr);
        topAddr = baseAddr + poolsize;
        auto nbits = cast(size_t)poolsize >> shiftBy;

        mark.alloc(nbits);
        if (ConservativeGC.isPrecise)
        {
            if (isLargeObject)
            {
                rtinfo = cast(immutable(size_t)**)cstdlib.malloc(npages * (size_t*).sizeof);
                if (!rtinfo)
                    onOutOfMemoryErrorNoGC();
                memset(rtinfo, 0, npages * (size_t*).sizeof);
            }
            else
            {
                is_pointer.alloc(cast(size_t)poolsize/(void*).sizeof);
                is_pointer.clrRange(0, is_pointer.nbits);
            }
        }

        // pagetable already keeps track of what's free for the large object
        // pool.
        if (!isLargeObject)
        {
            freebits.alloc(nbits);
            freebits.setRange(0, nbits);
        }

        noscan.alloc(nbits);
        appendable.alloc(nbits);

        pagetable = cast(ubyte*)cstdlib.malloc(npages);
        if (!pagetable)
            onOutOfMemoryErrorNoGC();

        if (npages > 0)
        {
            bPageOffsets = cast(uint*)cstdlib.malloc(npages * uint.sizeof);
            if (!bPageOffsets)
                onOutOfMemoryErrorNoGC();

            if (isLargeObject)
            {
                bPageOffsets[0] = cast(uint)npages;
                bPageOffsets[npages-1] = cast(uint)npages;
            }
            else
            {
                // all pages free
                foreach (n; 0..npages)
                    binPageChain[n] = cast(uint)(n + 1);
                recoverPageFirst[] = cast(uint)npages;
            }
        }

        memset(pagetable, B_FREE, npages);

        this.npages = npages;
        this.freepages = npages;
        this.searchStart = 0;
        this.largestFree = npages;
    }


    void Dtor() nothrow
    {
        if (baseAddr)
        {
            int result;

            if (npages)
            {
                result = os_mem_unmap(baseAddr, npages * PAGESIZE);
                assert(result == 0);
                npages = 0;
            }

            baseAddr = null;
            topAddr = null;
        }
        if (pagetable)
        {
            cstdlib.free(pagetable);
            pagetable = null;
        }

        if (bPageOffsets)
        {
            cstdlib.free(bPageOffsets);
            bPageOffsets = null;
        }

        mark.Dtor();
        if (ConservativeGC.isPrecise)
        {
            if (isLargeObject)
                cstdlib.free(rtinfo);
            else
                is_pointer.Dtor();
        }
        if (isLargeObject)
        {
            nointerior.Dtor();
        }
        else
        {
            freebits.Dtor();
        }
        finals.Dtor();
        structFinals.Dtor();
        noscan.Dtor();
        appendable.Dtor();
    }

    /**
    *
    */
    uint getBits(size_t biti) nothrow
    {
        uint bits;

        if (finals.nbits && finals.test(biti))
            bits |= BlkAttr.FINALIZE;
        if (structFinals.nbits && structFinals.test(biti))
            bits |= BlkAttr.STRUCTFINAL;
        if (noscan.test(biti))
            bits |= BlkAttr.NO_SCAN;
        if (nointerior.nbits && nointerior.test(biti))
            bits |= BlkAttr.NO_INTERIOR;
        if (appendable.test(biti))
            bits |= BlkAttr.APPENDABLE;
        return bits;
    }

    /**
     *
     */
    void clrBits(size_t biti, uint mask) nothrow @nogc
    {
        immutable dataIndex =  biti >> GCBits.BITS_SHIFT;
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable keep = ~(GCBits.BITS_1 << bitOffset);

        if (mask & BlkAttr.FINALIZE && finals.nbits)
            finals.data[dataIndex] &= keep;

        if (structFinals.nbits && (mask & BlkAttr.STRUCTFINAL))
            structFinals.data[dataIndex] &= keep;

        if (mask & BlkAttr.NO_SCAN)
            noscan.data[dataIndex] &= keep;
        if (mask & BlkAttr.APPENDABLE)
            appendable.data[dataIndex] &= keep;
        if (nointerior.nbits && (mask & BlkAttr.NO_INTERIOR))
            nointerior.data[dataIndex] &= keep;
    }

    /**
     *
     */
    void setBits(size_t biti, uint mask) nothrow
    {
        // Calculate the mask and bit offset once and then use it to
        // set all of the bits we need to set.
        immutable dataIndex = biti >> GCBits.BITS_SHIFT;
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable orWith = GCBits.BITS_1 << bitOffset;

        if (mask & BlkAttr.STRUCTFINAL)
        {
            if (!structFinals.nbits)
                structFinals.alloc(mark.nbits);
            structFinals.data[dataIndex] |= orWith;
        }

        if (mask & BlkAttr.FINALIZE)
        {
            if (!finals.nbits)
                finals.alloc(mark.nbits);
            finals.data[dataIndex] |= orWith;
        }

        if (mask & BlkAttr.NO_SCAN)
        {
            noscan.data[dataIndex] |= orWith;
        }
//        if (mask & BlkAttr.NO_MOVE)
//        {
//            if (!nomove.nbits)
//                nomove.alloc(mark.nbits);
//            nomove.data[dataIndex] |= orWith;
//        }
        if (mask & BlkAttr.APPENDABLE)
        {
            appendable.data[dataIndex] |= orWith;
        }

        if (isLargeObject && (mask & BlkAttr.NO_INTERIOR))
        {
            if (!nointerior.nbits)
                nointerior.alloc(mark.nbits);
            nointerior.data[dataIndex] |= orWith;
        }
    }

    void freePageBits(size_t pagenum, in ref PageBits toFree) nothrow
    {
        assert(!isLargeObject);
        assert(!nointerior.nbits); // only for large objects

        import core.internal.traits : staticIota;
        immutable beg = pagenum * (PAGESIZE / 16 / GCBits.BITS_PER_WORD);
        foreach (i; staticIota!(0, PageBits.length))
        {
            immutable w = toFree[i];
            if (!w) continue;

            immutable wi = beg + i;
            freebits.data[wi] |= w;
            noscan.data[wi] &= ~w;
            appendable.data[wi] &= ~w;
        }

        if (finals.nbits)
        {
            foreach (i; staticIota!(0, PageBits.length))
                if (toFree[i])
                    finals.data[beg + i] &= ~toFree[i];
        }

        if (structFinals.nbits)
        {
            foreach (i; staticIota!(0, PageBits.length))
                if (toFree[i])
                    structFinals.data[beg + i] &= ~toFree[i];
        }
    }

    void freeAllPageBits(size_t pagenum) nothrow
    {
        assert(!isLargeObject);
        assert(!nointerior.nbits); // only for large objects

        immutable beg = pagenum * PageBits.length;
        static foreach (i; 0 .. PageBits.length)
        {{
            immutable w = beg + i;
            freebits.data[w] = ~0;
            noscan.data[w] = 0;
            appendable.data[w] = 0;
            if (finals.data)
                finals.data[w] = 0;
            if (structFinals.data)
                structFinals.data[w] = 0;
        }}
    }

    /**
     * Given a pointer p in the p, return the pagenum.
     */
    size_t pagenumOf(void *p) const nothrow @nogc
    in
    {
        assert(p >= baseAddr);
        assert(p < topAddr);
    }
    do
    {
        return cast(size_t)(p - baseAddr) / PAGESIZE;
    }

    public
    @property bool isFree() const pure nothrow
    {
        return npages == freepages;
    }

    /**
     * Return number of pages necessary for an allocation of the given size
     *
     * returns size_t.max if more than uint.max pages are requested
     * (return type is still size_t to avoid truncation when being used
     *  in calculations, e.g. npages * PAGESIZE)
     */
    static size_t numPages(size_t size) nothrow @nogc
    {
        version (D_LP64)
        {
            if (size > PAGESIZE * cast(size_t)uint.max)
                return size_t.max;
        }
        else
        {
            if (size > size_t.max - PAGESIZE)
                return size_t.max;
        }
        return (size + PAGESIZE - 1) / PAGESIZE;
    }

    void* findBase(void* p) nothrow @nogc
    {
        size_t offset = cast(size_t)(p - baseAddr);
        size_t pn = offset / PAGESIZE;
        Bins   bin = cast(Bins)pagetable[pn];

        // Adjust bit to be at start of allocated memory block
        if (bin < B_NUMSMALL)
        {
            auto baseOff = baseOffset(offset, bin);
            const biti = baseOff >> Pool.ShiftBy.Small;
            if (freebits.test (biti))
                return null;
            return baseAddr + baseOff;
        }
        if (bin == B_PAGE)
        {
            return baseAddr + (offset & (offset.max ^ (PAGESIZE-1)));
        }
        if (bin == B_PAGEPLUS)
        {
            size_t pageOffset = bPageOffsets[pn];
            offset -= pageOffset * PAGESIZE;
            pn -= pageOffset;

            return baseAddr + (offset & (offset.max ^ (PAGESIZE-1)));
        }
        // we are in a B_FREE page
        assert(bin == B_FREE);
        return null;
    }

    size_t slGetSize(void* p) nothrow @nogc
    {
        if (isLargeObject)
            return (cast(LargeObjectPool*)&this).getPages(p) * PAGESIZE;
        else
            return (cast(SmallObjectPool*)&this).getSize(p);
    }

    BlkInfo slGetInfo(void* p) nothrow
    {
        if (isLargeObject)
            return (cast(LargeObjectPool*)&this).getInfo(p);
        else
            return (cast(SmallObjectPool*)&this).getInfo(p);
    }


    void Invariant() const {}

    debug(INVARIANT)
    invariant()
    {
        if (baseAddr)
        {
            //if (baseAddr + npages * PAGESIZE != topAddr)
                //printf("baseAddr = %p, npages = %d, topAddr = %p\n", baseAddr, npages, topAddr);
            assert(baseAddr + npages * PAGESIZE == topAddr);
        }

        if (pagetable !is null)
        {
            for (size_t i = 0; i < npages; i++)
            {
                Bins bin = cast(Bins)pagetable[i];
                assert(bin < B_MAX);
            }
        }
    }

    pragma(inline,true)
    void setPointerBitmapSmall(void* p, size_t s, size_t allocSize, uint attr, const TypeInfo ti) nothrow
    {
        if (!(attr & BlkAttr.NO_SCAN))
            setPointerBitmap(p, s, allocSize, ti, attr);
    }

    pragma(inline,false)
    void setPointerBitmap(void* p, size_t s, size_t allocSize, const TypeInfo ti, uint attr) nothrow
    {
        size_t offset = p - baseAddr;
        //debug(PRINTF) printGCBits(&pool.is_pointer);

        debug(PRINTF)
            printf("Setting a pointer bitmap for %s at %p + %llu\n", debugTypeName(ti).ptr, p, cast(ulong)s);

        if (ti)
        {
            if (attr & BlkAttr.APPENDABLE)
            {
                // an array of classes is in fact an array of pointers
                if (typeid(ti) is typeid(TypeInfo_Class))
                    goto L_conservative;
                s = allocSize;
            }

            auto rtInfo = cast(const(size_t)*)ti.rtInfo();

            if (rtInfo is rtinfoNoPointers)
            {
                debug(PRINTF) printf("\tCompiler generated rtInfo: no pointers\n");
                is_pointer.clrRange(offset/(void*).sizeof, s/(void*).sizeof);
            }
            else if (rtInfo is rtinfoHasPointers)
            {
                debug(PRINTF) printf("\tCompiler generated rtInfo: has pointers\n");
                is_pointer.setRange(offset/(void*).sizeof, s/(void*).sizeof);
            }
            else
            {
                const(size_t)* bitmap = cast (size_t*) rtInfo;
                //first element of rtInfo is the size of the object the bitmap encodes
                size_t element_size = * bitmap;
                bitmap++;
                size_t tocopy;
                if (attr & BlkAttr.APPENDABLE)
                {
                    tocopy = s/(void*).sizeof;
                    is_pointer.copyRangeRepeating(offset/(void*).sizeof, tocopy, bitmap, element_size/(void*).sizeof);
                }
                else
                {
                    tocopy = (s < element_size ? s : element_size)/(void*).sizeof;
                    is_pointer.copyRange(offset/(void*).sizeof, tocopy, bitmap);
                }

                debug(PRINTF) printf("\tSetting bitmap for new object (%s)\n\t\tat %p\t\tcopying from %p + %llu: ",
                                     debugTypeName(ti).ptr, p, bitmap, cast(ulong)element_size);
                debug(PRINTF)
                    for (size_t i = 0; i < element_size/((void*).sizeof); i++)
                        printf("%d", (bitmap[i/(8*size_t.sizeof)] >> (i%(8*size_t.sizeof))) & 1);
                debug(PRINTF) printf("\n");

                if (tocopy * (void*).sizeof < s) // better safe than sorry: if allocated more, assume pointers inside
                {
                    debug(PRINTF) printf("    Appending %d pointer bits\n", s/(void*).sizeof - tocopy);
                    is_pointer.setRange(offset/(void*).sizeof + tocopy, s/(void*).sizeof - tocopy);
                }
            }

            if (s < allocSize)
            {
                offset = (offset + s + (void*).sizeof - 1) & ~((void*).sizeof - 1);
                is_pointer.clrRange(offset/(void*).sizeof, (allocSize - s)/(void*).sizeof);
            }
        }
        else
        {
        L_conservative:
            // limit pointers to actual size of allocation? might fail for arrays that append
            // without notifying the GC
            s = allocSize;

            debug(PRINTF) printf("Allocating a block without TypeInfo\n");
            is_pointer.setRange(offset/(void*).sizeof, s/(void*).sizeof);
        }
        //debug(PRINTF) printGCBits(&pool.is_pointer);
    }
}

struct LargeObjectPool
{
    Pool base;
    alias base this;

    debug(INVARIANT)
    void Invariant()
    {
        //base.Invariant();
        for (size_t n = 0; n < npages; )
        {
            uint np = bPageOffsets[n];
            assert(np > 0 && np <= npages - n);

            if (pagetable[n] == B_PAGE)
            {
                for (uint p = 1; p < np; p++)
                {
                    assert(pagetable[n + p] == B_PAGEPLUS);
                    assert(bPageOffsets[n + p] == p);
                }
            }
            else if (pagetable[n] == B_FREE)
            {
                for (uint p = 1; p < np; p++)
                {
                    assert(pagetable[n + p] == B_FREE);
                }
                assert(bPageOffsets[n + np - 1] == np);
            }
            else
                assert(false);
            n += np;
        }
    }

    /**
     * Allocate n pages from Pool.
     * Returns OPFAIL on failure.
     */
    size_t allocPages(size_t n) nothrow
    {
        if (largestFree < n || searchStart + n > npages)
            return OPFAIL;

        //debug(PRINTF) printf("Pool::allocPages(n = %d)\n", n);
        size_t largest = 0;
        if (pagetable[searchStart] == B_PAGEPLUS)
        {
            searchStart -= bPageOffsets[searchStart]; // jump to B_PAGE
            searchStart += bPageOffsets[searchStart];
        }
        while (searchStart < npages && pagetable[searchStart] == B_PAGE)
            searchStart += bPageOffsets[searchStart];

        for (size_t i = searchStart; i < npages; )
        {
            assert(pagetable[i] == B_FREE);

            auto p = bPageOffsets[i];
            if (p > n)
            {
                setFreePageOffsets(i + n, p - n);
                goto L_found;
            }
            if (p == n)
            {
            L_found:
                pagetable[i] = B_PAGE;
                bPageOffsets[i] = cast(uint) n;
                if (n > 1)
                {
                    memset(&pagetable[i + 1], B_PAGEPLUS, n - 1);
                    for (auto offset = 1; offset < n; offset++)
                        bPageOffsets[i + offset] = cast(uint) offset;
                }
                freepages -= n;
                return i;
            }
            if (p > largest)
                largest = p;

            i += p;
            while (i < npages && pagetable[i] == B_PAGE)
            {
                // we have the size information, so we skip a whole bunch of pages.
                i += bPageOffsets[i];
            }
        }

        // not enough free pages found, remember largest free chunk
        largestFree = largest;
        return OPFAIL;
    }

    /**
     * Free npages pages starting with pagenum.
     */
    void freePages(size_t pagenum, size_t npages) nothrow @nogc
    {
        //memset(&pagetable[pagenum], B_FREE, npages);
        if (pagenum < searchStart)
            searchStart = pagenum;

        for (size_t i = pagenum; i < npages + pagenum; i++)
        {
            assert(pagetable[i] < B_FREE);
            pagetable[i] = B_FREE;
        }
        freepages += npages;
        largestFree = freepages; // invalidate
    }

    /**
     * Set the first and the last entry of a B_FREE block to the size
     */
    void setFreePageOffsets(size_t page, size_t num) nothrow @nogc
    {
        assert(pagetable[page] == B_FREE);
        assert(pagetable[page + num - 1] == B_FREE);
        bPageOffsets[page] = cast(uint)num;
        if (num > 1)
            bPageOffsets[page + num - 1] = cast(uint)num;
    }

    void mergeFreePageOffsets(bool bwd, bool fwd)(size_t page, size_t num) nothrow @nogc
    {
        static if (bwd)
        {
            if (page > 0 && pagetable[page - 1] == B_FREE)
            {
                auto sz = bPageOffsets[page - 1];
                page -= sz;
                num += sz;
            }
        }
        static if (fwd)
        {
            if (page + num < npages && pagetable[page + num] == B_FREE)
                num += bPageOffsets[page + num];
        }
        setFreePageOffsets(page, num);
    }

    /**
     * Get pages of allocation at pointer p in pool.
     */
    size_t getPages(void *p) const nothrow @nogc
    in
    {
        assert(p >= baseAddr);
        assert(p < topAddr);
    }
    do
    {
        if (cast(size_t)p & (PAGESIZE - 1)) // check for interior pointer
            return 0;
        size_t pagenum = pagenumOf(p);
        Bins bin = cast(Bins)pagetable[pagenum];
        if (bin != B_PAGE)
            return 0;
        return bPageOffsets[pagenum];
    }

    /**
    * Get size of allocation at page pn in pool.
    */
    size_t getSize(size_t pn) const nothrow @nogc
    {
        assert(pagetable[pn] == B_PAGE);
        return cast(size_t) bPageOffsets[pn] * PAGESIZE;
    }

    /**
    *
    */
    BlkInfo getInfo(void* p) nothrow
    {
        BlkInfo info;

        size_t offset = cast(size_t)(p - baseAddr);
        size_t pn = offset / PAGESIZE;
        Bins bin = cast(Bins)pagetable[pn];

        if (bin == B_PAGEPLUS)
            pn -= bPageOffsets[pn];
        else if (bin != B_PAGE)
            return info;           // no info for free pages

        info.base = baseAddr + pn * PAGESIZE;
        info.size = getSize(pn);
        info.attr = getBits(pn);
        return info;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        foreach (pn; 0 .. npages)
        {
            Bins bin = cast(Bins)pagetable[pn];
            if (bin > B_PAGE)
                continue;
            size_t biti = pn;

            if (!finals.test(biti))
                continue;

            auto p = sentinel_add(baseAddr + pn * PAGESIZE);
            size_t size = sentinel_size(p, getSize(pn));
            uint attr = getBits(biti);

            if (!rt_hasFinalizerInSegment(p, size, attr, segment))
                continue;

            rt_finalizeFromGC(p, size, attr);

            clrBits(biti, ~BlkAttr.NONE);

            if (pn < searchStart)
                searchStart = pn;

            debug(COLLECT_PRINTF) printf("\tcollecting big %p\n", p);
            //log_free(sentinel_add(p));

            size_t n = 1;
            for (; pn + n < npages; ++n)
                if (pagetable[pn + n] != B_PAGEPLUS)
                    break;
            debug (MEMSTOMP) memset(baseAddr + pn * PAGESIZE, 0xF3, n * PAGESIZE);
            freePages(pn, n);
            mergeFreePageOffsets!(true, true)(pn, n);
        }
    }
}


struct SmallObjectPool
{
    Pool base;
    alias base this;

    debug(INVARIANT)
    void Invariant()
    {
        //base.Invariant();
        uint cntRecover = 0;
        foreach (Bins bin; 0 .. B_NUMSMALL)
        {
            for (auto pn = recoverPageFirst[bin]; pn < npages; pn = binPageChain[pn])
            {
                assert(pagetable[pn] == bin);
                cntRecover++;
            }
        }
        uint cntFree = 0;
        for (auto pn = searchStart; pn < npages; pn = binPageChain[pn])
        {
            assert(pagetable[pn] == B_FREE);
            cntFree++;
        }
        assert(cntFree == freepages);
        assert(cntFree + cntRecover <= npages);
    }

    /**
    * Get size of pointer p in pool.
    */
    size_t getSize(void *p) const nothrow @nogc
    in
    {
        assert(p >= baseAddr);
        assert(p < topAddr);
    }
    do
    {
        size_t pagenum = pagenumOf(p);
        Bins bin = cast(Bins)pagetable[pagenum];
        assert(bin < B_PAGE);
        if (p != cast(void*)baseOffset(cast(size_t)p, bin)) // check for interior pointer
            return 0;
        const biti = cast(size_t)(p - baseAddr) >> ShiftBy.Small;
        if (freebits.test (biti))
            return 0;
        return binsize[bin];
    }

    BlkInfo getInfo(void* p) nothrow
    {
        BlkInfo info;
        size_t offset = cast(size_t)(p - baseAddr);
        size_t pn = offset / PAGESIZE;
        Bins   bin = cast(Bins)pagetable[pn];

        if (bin >= B_PAGE)
            return info;

        auto base = cast(void*)baseOffset(cast(size_t)p, bin);
        const biti = cast(size_t)(base - baseAddr) >> ShiftBy.Small;
        if (freebits.test (biti))
            return info;

        info.base = base;
        info.size = binsize[bin];
        offset = info.base - baseAddr;
        info.attr = getBits(biti);

        return info;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        foreach (pn; 0 .. npages)
        {
            Bins bin = cast(Bins)pagetable[pn];
            if (bin >= B_PAGE)
                continue;

            immutable size = binsize[bin];
            auto p = baseAddr + pn * PAGESIZE;
            const ptop = p + PAGESIZE - size + 1;
            immutable base = pn * (PAGESIZE/16);
            immutable bitstride = size / 16;

            bool freeBits;
            PageBits toFree;

            for (size_t i; p < ptop; p += size, i += bitstride)
            {
                immutable biti = base + i;

                if (!finals.test(biti))
                    continue;

                auto q = sentinel_add(p);
                uint attr = getBits(biti);
                const ssize = sentinel_size(q, size);
                if (!rt_hasFinalizerInSegment(q, ssize, attr, segment))
                    continue;

                rt_finalizeFromGC(q, ssize, attr);

                freeBits = true;
                toFree.set(i);

                debug(COLLECT_PRINTF) printf("\tcollecting %p\n", p);
                //log_free(sentinel_add(p));

                debug (MEMSTOMP) memset(p, 0xF3, size);
            }

            if (freeBits)
                freePageBits(pn, toFree);
        }
    }

    /**
    * Allocate a page of bin's.
    * Returns:
    *           head of a single linked list of new entries
    */
    List* allocPage(Bins bin) nothrow
    {
        if (searchStart >= npages)
            return null;

        assert(pagetable[searchStart] == B_FREE);

    L1:
        size_t pn = searchStart;
        searchStart = binPageChain[searchStart];
        binPageChain[pn] = Pool.PageRecovered;
        pagetable[pn] = cast(ubyte)bin;
        freepages--;

        // Convert page to free list
        size_t size = binsize[bin];
        void* p = baseAddr + pn * PAGESIZE;
        auto first = cast(List*) p;

        // ensure 2 <size> bytes blocks are available below ptop, one
        //  being set in the loop, and one for the tail block
        void* ptop = p + PAGESIZE - 2 * size + 1;
        for (; p < ptop; p += size)
        {
            (cast(List *)p).next = cast(List *)(p + size);
            (cast(List *)p).pool = &base;
        }
        (cast(List *)p).next = null;
        (cast(List *)p).pool = &base;
        return first;
    }
}

debug(SENTINEL) {} else // no additional capacity with SENTINEL
unittest // bugzilla 14467
{
    int[] arr = new int[10];
    assert(arr.capacity);
    arr = arr[$..$];
    assert(arr.capacity);
}

unittest // bugzilla 15353
{
    import core.memory : GC;

    static struct Foo
    {
        ~this()
        {
            GC.free(buf); // ignored in finalizer
        }

        void* buf;
    }
    new Foo(GC.malloc(10));
    GC.collect();
}

unittest // bugzilla 15822
{
    import core.memory : GC;

    __gshared ubyte[16] buf;
    static struct Foo
    {
        ~this()
        {
            GC.removeRange(ptr);
            GC.removeRoot(ptr);
        }

        ubyte* ptr;
    }
    GC.addRoot(buf.ptr);
    GC.addRange(buf.ptr, buf.length);
    new Foo(buf.ptr);
    GC.collect();
}

unittest // bugzilla 1180
{
    import core.exception;
    try
    {
        size_t x = size_t.max - 100;
        byte[] big_buf = new byte[x];
    }
    catch (OutOfMemoryError)
    {
    }
}

/* ============================ PRINTF =============================== */

debug(PRINTF_TO_FILE)
{
    private __gshared MonoTime gcStartTick;
    private __gshared FILE* gcx_fh;
    private __gshared bool hadNewline = false;
    import core.internal.spinlock;
    static printLock = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);

    private int printf(ARGS...)(const char* fmt, ARGS args) nothrow
    {
        printLock.lock();
        scope(exit) printLock.unlock();

        if (!gcx_fh)
            gcx_fh = fopen("gcx.log", "w");
        if (!gcx_fh)
            return 0;

        int len;
        if (MonoTime.ticksPerSecond == 0)
        {
            len = fprintf(gcx_fh, "before init: ");
        }
        else if (hadNewline)
        {
            if (gcStartTick == MonoTime.init)
                gcStartTick = MonoTime.currTime;
            immutable timeElapsed = MonoTime.currTime - gcStartTick;
            immutable secondsAsDouble = timeElapsed.total!"hnsecs" / cast(double)convert!("seconds", "hnsecs")(1);
            len = fprintf(gcx_fh, "%10.6lf: ", secondsAsDouble);
        }
        len += fprintf(gcx_fh, fmt, args);
        fflush(gcx_fh);
        import core.stdc.string;
        hadNewline = fmt && fmt[0] && fmt[strlen(fmt) - 1] == '\n';
        return len;
    }
}

debug(PRINTF) void printFreeInfo(Pool* pool) nothrow
{
    uint nReallyFree;
    foreach (i; 0..pool.npages) {
        if (pool.pagetable[i] >= B_FREE) nReallyFree++;
    }

    printf("Pool %p:  %d really free, %d supposedly free\n", pool, nReallyFree, pool.freepages);
}

debug(PRINTF)
void printGCBits(GCBits* bits)
{
    for (size_t i = 0; i < bits.nwords; i++)
    {
        if (i % 32 == 0) printf("\n\t");
        printf("%x ", bits.data[i]);
    }
    printf("\n");
}

// we can assume the name is always from a literal, so it is zero terminated
debug(PRINTF)
string debugTypeName(const(TypeInfo) ti) nothrow
{
    string name;
    if (ti is null)
        name = "null";
    else if (auto ci = cast(TypeInfo_Class)ti)
        name = ci.name;
    else if (auto si = cast(TypeInfo_Struct)ti)
        name = si.name;
    else if (auto ci = cast(TypeInfo_Const)ti)
        static if (__traits(compiles,ci.base)) // different whether compiled with object.di or object.d
            return debugTypeName(ci.base);
        else
            return debugTypeName(ci.next);
    else
        name = ti.classinfo.name;
    return name;
}

/* ======================= Leak Detector =========================== */

debug (LOGGING)
{
    struct Log
    {
        void*  p;
        size_t size;
        size_t line;
        char*  file;
        void*  parent;

        void print() nothrow
        {
            printf("    p = %p, size = %lld, parent = %p ", p, cast(ulong)size, parent);
            if (file)
            {
                printf("%s(%u)", file, line);
            }
            printf("\n");
        }
    }


    struct LogArray
    {
        size_t dim;
        size_t allocdim;
        Log *data;

        void Dtor() nothrow @nogc
        {
            if (data)
                cstdlib.free(data);
            data = null;
        }

        void reserve(size_t nentries) nothrow @nogc
        {
            assert(dim <= allocdim);
            if (allocdim - dim < nentries)
            {
                allocdim = (dim + nentries) * 2;
                assert(dim + nentries <= allocdim);
                if (!data)
                {
                    data = cast(Log*)cstdlib.malloc(allocdim * Log.sizeof);
                    if (!data && allocdim)
                        onOutOfMemoryErrorNoGC();
                }
                else
                {   Log *newdata;

                    newdata = cast(Log*)cstdlib.malloc(allocdim * Log.sizeof);
                    if (!newdata && allocdim)
                        onOutOfMemoryErrorNoGC();
                    memcpy(newdata, data, dim * Log.sizeof);
                    cstdlib.free(data);
                    data = newdata;
                }
            }
        }


        void push(Log log) nothrow @nogc
        {
            reserve(1);
            data[dim++] = log;
        }

        void remove(size_t i) nothrow @nogc
        {
            memmove(data + i, data + i + 1, (dim - i) * Log.sizeof);
            dim--;
        }


        size_t find(void *p) nothrow @nogc
        {
            for (size_t i = 0; i < dim; i++)
            {
                if (data[i].p == p)
                    return i;
            }
            return OPFAIL; // not found
        }


        void copy(LogArray *from) nothrow @nogc
        {
            if (allocdim < from.dim)
                reserve(from.dim - dim);
            assert(from.dim <= allocdim);
            memcpy(data, from.data, from.dim * Log.sizeof);
            dim = from.dim;
        }
    }

    struct LeakDetector
    {
        Gcx* gcx;
        LogArray current;
        LogArray prev;

        private void initialize(Gcx* gc)
        {
            gcx = gc;
            //debug(PRINTF) printf("+log_init()\n");
            current.reserve(1000);
            prev.reserve(1000);
            //debug(PRINTF) printf("-log_init()\n");
        }


        private void log_malloc(void *p, size_t size) nothrow
        {
            //debug(PRINTF) printf("+log_malloc(p = %p, size = %zd)\n", p, size);
            Log log;

            log.p = p;
            log.size = size;
            log.line = ConservativeGC.line;
            log.file = ConservativeGC.file;
            log.parent = null;

            ConservativeGC.line = 0;
            ConservativeGC.file = null;

            current.push(log);
            //debug(PRINTF) printf("-log_malloc()\n");
        }


        private void log_free(void *p) nothrow @nogc
        {
            //debug(PRINTF) printf("+log_free(%p)\n", p);
            auto i = current.find(p);
            if (i == OPFAIL)
            {
                debug(PRINTF) printf("free'ing unallocated memory %p\n", p);
            }
            else
                current.remove(i);
            //debug(PRINTF) printf("-log_free()\n");
        }


        private void log_collect() nothrow
        {
            //debug(PRINTF) printf("+log_collect()\n");
            // Print everything in current that is not in prev

            debug(PRINTF) printf("New pointers this cycle: --------------------------------\n");
            size_t used = 0;
            for (size_t i = 0; i < current.dim; i++)
            {
                auto j = prev.find(current.data[i].p);
                if (j == OPFAIL)
                    current.data[i].print();
                else
                    used++;
            }

            debug(PRINTF) printf("All roots this cycle: --------------------------------\n");
            for (size_t i = 0; i < current.dim; i++)
            {
                void* p = current.data[i].p;
                if (!gcx.findPool(current.data[i].parent))
                {
                    auto j = prev.find(current.data[i].p);
                    debug(PRINTF) printf(j == OPFAIL ? "N" : " ");
                    current.data[i].print();
                }
            }

            debug(PRINTF) printf("Used = %d-------------------------------------------------\n", used);
            prev.copy(&current);

            debug(PRINTF) printf("-log_collect()\n");
        }


        private void log_parent(void *p, void *parent) nothrow
        {
            //debug(PRINTF) printf("+log_parent()\n");
            auto i = current.find(p);
            if (i == OPFAIL)
            {
                debug(PRINTF) printf("parent'ing unallocated memory %p, parent = %p\n", p, parent);
                Pool *pool;
                pool = gcx.findPool(p);
                assert(pool);
                size_t offset = cast(size_t)(p - pool.baseAddr);
                size_t biti;
                size_t pn = offset / PAGESIZE;
                Bins bin = cast(Bins)pool.pagetable[pn];
                biti = (offset & (PAGESIZE - 1)) >> pool.shiftBy;
                debug(PRINTF) printf("\tbin = %d, offset = x%x, biti = x%x\n", bin, offset, biti);
            }
            else
            {
                current.data[i].parent = parent;
            }
            //debug(PRINTF) printf("-log_parent()\n");
        }
    }
}
else
{
    struct LeakDetector
    {
        static void initialize(Gcx* gcx) nothrow { }
        static void log_malloc(void *p, size_t size) nothrow { }
        static void log_free(void *p) nothrow @nogc { }
        static void log_collect() nothrow { }
        static void log_parent(void *p, void *parent) nothrow { }
    }
}

/* ============================ SENTINEL =============================== */

debug (SENTINEL)
{
    // pre-sentinel must be smaller than 16 bytes so that the same GC bits
    //  are used for the allocated pointer and the user pointer
    // so use uint for both 32 and 64 bit platforms, limiting usage to < 4GB
    const uint  SENTINEL_PRE = 0xF4F4F4F4;
    const ubyte SENTINEL_POST = 0xF5;           // 8 bits
    const uint  SENTINEL_EXTRA = 2 * uint.sizeof + 1;


    inout(uint*)  sentinel_psize(inout void *p) nothrow @nogc { return &(cast(inout uint *)p)[-2]; }
    inout(uint*)  sentinel_pre(inout void *p)   nothrow @nogc { return &(cast(inout uint *)p)[-1]; }
    inout(ubyte*) sentinel_post(inout void *p)  nothrow @nogc { return &(cast(inout ubyte *)p)[*sentinel_psize(p)]; }


    void sentinel_init(void *p, size_t size) nothrow @nogc
    {
        assert(size <= uint.max);
        *sentinel_psize(p) = cast(uint)size;
        *sentinel_pre(p) = SENTINEL_PRE;
        *sentinel_post(p) = SENTINEL_POST;
    }


    void sentinel_Invariant(const void *p) nothrow @nogc
    {
        debug
        {
            assert(*sentinel_pre(p) == SENTINEL_PRE);
            assert(*sentinel_post(p) == SENTINEL_POST);
        }
        else if (*sentinel_pre(p) != SENTINEL_PRE || *sentinel_post(p) != SENTINEL_POST)
            onInvalidMemoryOperationError(); // also trigger in release build
    }

    size_t sentinel_size(const void *p, size_t alloc_size) nothrow @nogc
    {
        return *sentinel_psize(p);
    }

    void *sentinel_add(void *p) nothrow @nogc
    {
        return p + 2 * uint.sizeof;
    }


    void *sentinel_sub(void *p) nothrow @nogc
    {
        return p - 2 * uint.sizeof;
    }
}
else
{
    const uint SENTINEL_EXTRA = 0;


    void sentinel_init(void *p, size_t size) nothrow @nogc
    {
    }


    void sentinel_Invariant(const void *p) nothrow @nogc
    {
    }

    size_t sentinel_size(const void *p, size_t alloc_size) nothrow @nogc
    {
        return alloc_size;
    }

    void *sentinel_add(void *p) nothrow @nogc
    {
        return p;
    }


    void *sentinel_sub(void *p) nothrow @nogc
    {
        return p;
    }
}

debug (MEMSTOMP)
unittest
{
    import core.memory;
    auto p = cast(uint*)GC.malloc(uint.sizeof*5);
    assert(*p == 0xF0F0F0F0);
    p[2] = 0; // First two will be used for free list
    GC.free(p);
    assert(p[4] == 0xF2F2F2F2); // skip List usage, for both 64-bit and 32-bit
}

debug (SENTINEL)
unittest
{
    import core.memory;
    auto p = cast(ubyte*)GC.malloc(1);
    assert(p[-1] == 0xF4);
    assert(p[ 1] == 0xF5);
/*
    p[1] = 0;
    bool thrown;
    try
        GC.free(p);
    catch (Error e)
        thrown = true;
    p[1] = 0xF5;
    assert(thrown);
*/
}

unittest
{
    import core.memory;

    // https://issues.dlang.org/show_bug.cgi?id=9275
    GC.removeRoot(null);
    GC.removeRoot(cast(void*)13);
}

// improve predictability of coverage of code that is eventually not hit by other tests
debug (SENTINEL) {} else // cannot extend with SENTINEL
debug (MARK_PRINTF) {} else // takes forever
unittest
{
    import core.memory;
    auto p = GC.malloc(260 << 20); // new pool has 390 MB
    auto q = GC.malloc(65 << 20);  // next chunk (larger than 64MB to ensure the same pool is used)
    auto r = GC.malloc(65 << 20);  // another chunk in same pool
    assert(p + (260 << 20) == q);
    assert(q + (65 << 20) == r);
    GC.free(q);
    // should trigger "assert(bin == B_FREE);" in mark due to dangling pointer q:
    GC.collect();
    // should trigger "break;" in extendNoSync:
    size_t sz = GC.extend(p, 64 << 20, 66 << 20); // trigger size after p large enough (but limited)
    assert(sz == 325 << 20);
    GC.free(p);
    GC.free(r);
    r = q; // ensure q is not trashed before collection above

    p = GC.malloc(70 << 20); // from the same pool
    q = GC.malloc(70 << 20);
    r = GC.malloc(70 << 20);
    auto s = GC.malloc(70 << 20);
    auto t = GC.malloc(70 << 20); // 350 MB of 390 MB used
    assert(p + (70 << 20) == q);
    assert(q + (70 << 20) == r);
    assert(r + (70 << 20) == s);
    assert(s + (70 << 20) == t);
    GC.free(r); // ensure recalculation of largestFree in nxxt allocPages
    auto z = GC.malloc(75 << 20); // needs new pool

    GC.free(p);
    GC.free(q);
    GC.free(s);
    GC.free(t);
    GC.free(z);
    GC.minimize(); // release huge pool
}

// https://issues.dlang.org/show_bug.cgi?id=19281
debug (SENTINEL) {} else // cannot allow >= 4 GB with SENTINEL
debug (MEMSTOMP) {} else // might take too long to actually touch the memory
version (D_LP64) unittest
{
    static if (__traits(compiles, os_physical_mem))
    {
        // only run if the system has enough physical memory
        size_t sz = 2L^^32;
        //import core.stdc.stdio;
        //printf("availphys = %lld", os_physical_mem());
        if (os_physical_mem() > sz)
        {
            import core.memory;
            GC.collect();
            GC.minimize();
            auto stats = GC.stats();
            auto ptr = GC.malloc(sz, BlkAttr.NO_SCAN);
            auto info = GC.query(ptr);
            //printf("info.size = %lld", info.size);
            assert(info.size >= sz);
            GC.free(ptr);
            GC.minimize();
            auto nstats = GC.stats();
            assert(nstats.usedSize == stats.usedSize);
            assert(nstats.freeSize == stats.freeSize);
            assert(nstats.allocatedInCurrentThread - sz == stats.allocatedInCurrentThread);
        }
    }
}

// https://issues.dlang.org/show_bug.cgi?id=19522
unittest
{
    import core.memory;

    void test(void* p)
    {
        assert(GC.getAttr(p) == BlkAttr.NO_SCAN);
        assert(GC.setAttr(p + 4, BlkAttr.NO_SCAN) == 0); // interior pointer should fail
        assert(GC.clrAttr(p + 4, BlkAttr.NO_SCAN) == 0); // interior pointer should fail
        GC.free(p);
        assert(GC.query(p).base == null);
        assert(GC.query(p).size == 0);
        assert(GC.addrOf(p) == null);
        assert(GC.sizeOf(p) == 0); // fails
        assert(GC.getAttr(p) == 0);
        assert(GC.setAttr(p, BlkAttr.NO_SCAN) == 0);
        assert(GC.clrAttr(p, BlkAttr.NO_SCAN) == 0);
    }
    void* large = GC.malloc(10000, BlkAttr.NO_SCAN);
    test(large);

    void* small = GC.malloc(100, BlkAttr.NO_SCAN);
    test(small);
}

unittest
{
    import core.memory;

    auto now = currTime;
    GC.ProfileStats stats1 = GC.profileStats();
    GC.collect();
    GC.ProfileStats stats2 = GC.profileStats();
    auto diff = currTime - now;

    assert(stats2.totalCollectionTime - stats1.totalCollectionTime <= diff);
    assert(stats2.totalPauseTime - stats1.totalPauseTime <= stats2.totalCollectionTime - stats1.totalCollectionTime);

    assert(stats2.maxPauseTime >= stats1.maxPauseTime);
    assert(stats2.maxCollectionTime >= stats1.maxCollectionTime);
}
