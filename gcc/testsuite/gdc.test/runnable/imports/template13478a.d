module imports.template13478a;

// Make sure this is not inlined so template13478.o actually
// needs to reference it.
version (DigitalMars)
{
    bool foo(T)()
    {
        asm { nop; }
        return false;
    }
}

version (GNU)
{
    import gcc.attribute;
    @attribute("noinline") bool foo(T)()
    {
        return false;
    }
}

version (LDC)
{
    bool foo(T)()
    {
        asm { nop; }
        return false;
    }
}
