// https://gcc.gnu.org/bugzilla/show_bug.cgi?id=92309
// { dg-do run { target hw } }
union U
{
    struct
    {
        size_t a;
        size_t b;
        union
        {
            size_t c;
            size_t d;
        }
    }
}

void main()
{
    U u;
    assert(u.a == 0); // ok
    u.d = 1;
    assert(u.a == 0); // error
}
