module core.internal.lifetime;

/+
emplaceRef is a package function for druntime internal use. It works like
emplace, but takes its argument by ref (as opposed to "by pointer").
This makes it easier to use, easier to be safe, and faster in a non-inline
build.
Furthermore, emplaceRef optionally takes a type parameter, which specifies
the type we want to build. This helps to build qualified objects on mutable
buffer, without breaking the type system with unsafe casts.
+/
void emplaceRef(T, UT, Args...)(ref UT chunk, auto ref Args args)
{
    static if (args.length == 0)
    {
        static assert(is(typeof({static T i;})),
            "Cannot emplace a " ~ T.stringof ~ " because " ~ T.stringof ~
            ".this() is annotated with @disable.");
        static if (is(T == class)) static assert(!__traits(isAbstractClass, T),
            T.stringof ~ " is abstract and it can't be emplaced");
        emplaceInitializer(chunk);
    }
    else static if (
        !is(T == struct) && Args.length == 1 /* primitives, enums, arrays */
        ||
        Args.length == 1 && is(typeof({T t = args[0];})) /* conversions */
        ||
        is(typeof(T(args))) /* general constructors */)
    {
        static struct S
        {
            T payload;
            this(ref Args x)
            {
                static if (Args.length == 1)
                    static if (is(typeof(payload = x[0])))
                        payload = x[0];
                    else
                        payload = T(x[0]);
                else
                    payload = T(x);
            }
        }
        if (__ctfe)
        {
            static if (is(typeof(chunk = T(args))))
                chunk = T(args);
            else static if (args.length == 1 && is(typeof(chunk = args[0])))
                chunk = args[0];
            else assert(0, "CTFE emplace doesn't support "
                ~ T.stringof ~ " from " ~ Args.stringof);
        }
        else
        {
            S* p = () @trusted { return cast(S*) &chunk; }();
            static if (UT.sizeof > 0)
                emplaceInitializer(*p);
            p.__ctor(args);
        }
    }
    else static if (is(typeof(chunk.__ctor(args))))
    {
        // This catches the rare case of local types that keep a frame pointer
        emplaceInitializer(chunk);
        chunk.__ctor(args);
    }
    else
    {
        //We can't emplace. Try to diagnose a disabled postblit.
        static assert(!(Args.length == 1 && is(Args[0] : T)),
            "Cannot emplace a " ~ T.stringof ~ " because " ~ T.stringof ~
            ".this(this) is annotated with @disable.");

        //We can't emplace.
        static assert(false,
            T.stringof ~ " cannot be emplaced from " ~ Args[].stringof ~ ".");
    }
}

// ditto
static import core.internal.traits;
void emplaceRef(UT, Args...)(ref UT chunk, auto ref Args args)
if (is(UT == core.internal.traits.Unqual!UT))
{
    emplaceRef!(UT, UT)(chunk, args);
}

//emplace helper functions
private nothrow pure @trusted
void emplaceInitializer(T)(scope ref T chunk)
{
    import core.internal.traits : hasElaborateAssign, isAssignable;
    static if (!hasElaborateAssign!T && isAssignable!T)
        chunk = T.init;
    else
    {
        static if (__traits(isZeroInit, T))
        {
            import core.stdc.string : memset;
            memset(&chunk, 0, T.sizeof);
        }
        else
        {
            import core.stdc.string : memcpy;
            static immutable T init = T.init;
            memcpy(&chunk, &init, T.sizeof);
        }
    }
}
