// REQUIRED_ARGS: -o-
// PERMUTE_ARGS:

/***************** NewExp *******************/

struct S1 { }
struct S2 { this(int); }
struct S3 { this(int) @nogc; }

/*
TEST_OUTPUT:
---
fail_compilation/nogc1.d(24): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
fail_compilation/nogc1.d(26): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
fail_compilation/nogc1.d(27): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
fail_compilation/nogc1.d(29): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
fail_compilation/nogc1.d(30): Error: `@nogc` function `nogc1.testNew` cannot call non-@nogc constructor `nogc1.S2.this`
fail_compilation/nogc1.d(31): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
fail_compilation/nogc1.d(33): Error: cannot use `new` in `@nogc` function `nogc1.testNew`
---
*/
@nogc void testNew()
{
    int* p1 = new int;

    int[] a1 = new int[3];
    int[][] a2 = new int[][](2, 3);

    S1* ps1 = new S1();
    S2* ps2 = new S2(1);
    S3* ps3 = new S3(1);

    Object o1 = new Object();
}

/*
TEST_OUTPUT:
---
fail_compilation/nogc1.d(49): Error: cannot use `new` in `@nogc` function `nogc1.testNewScope`
fail_compilation/nogc1.d(51): Error: cannot use `new` in `@nogc` function `nogc1.testNewScope`
fail_compilation/nogc1.d(52): Error: cannot use `new` in `@nogc` function `nogc1.testNewScope`
fail_compilation/nogc1.d(54): Error: cannot use `new` in `@nogc` function `nogc1.testNewScope`
fail_compilation/nogc1.d(55): Error: `@nogc` function `nogc1.testNewScope` cannot call non-@nogc constructor `nogc1.S2.this`
fail_compilation/nogc1.d(56): Error: cannot use `new` in `@nogc` function `nogc1.testNewScope`
---
*/
@nogc void testNewScope()
{
    scope int* p1 = new int;

    scope int[] a1 = new int[3];
    scope int[][] a2 = new int[][](2, 3);

    scope S1* ps1 = new S1();
    scope S2* ps2 = new S2(1);
    scope S3* ps3 = new S3(1);

    scope Object o1 = new Object();     // no error
    scope o2 = new Object();            // no error
}

/***************** DeleteExp *******************/

/*
TEST_OUTPUT:
---
fail_compilation/nogc1.d(77): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
fail_compilation/nogc1.d(77): Error: cannot use `delete` in `@nogc` function `nogc1.testDelete`
fail_compilation/nogc1.d(78): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
fail_compilation/nogc1.d(78): Error: cannot use `delete` in `@nogc` function `nogc1.testDelete`
fail_compilation/nogc1.d(79): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
fail_compilation/nogc1.d(79): Error: cannot use `delete` in `@nogc` function `nogc1.testDelete`
---
*/
@nogc void testDelete(int* p, Object o, S1* s)
{
    delete p;
    delete o;
    delete s;
}
