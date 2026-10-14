// ffi_fixture.cpp: classes and functions whose MSVC x64 layouts and calling conventions the
// fnmatch.ffi declarations (stellar-fnmatch cdef) must reproduce; test_ffi.lua checks them
// against this DLL's PDB and, on Windows, calls them.
//
// Built by build_ffi_fixture.cmd with MSVC (cl /LD /O1 /Zi /EHsc /MD). Only <stdarg.h>, so
// the PDB stays small.

#include <stdarg.h>

typedef signed char int8_t;
typedef short int16_t;
typedef int int32_t;
typedef long long int64_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;

#define API extern "C" __declspec(dllexport)
#define EXP __declspec(dllexport)

// a POD of 8 bytes: free functions return it in RAX, it is passed in a register
struct Vec2 {
    float x, y;
};

// 24 bytes: returned through a hidden pointer, passed as a pointer to a copy
struct Big {
    int64_t a, b, c;
};

// 4 bytes with constructors and only a move constructor: not a POD (hidden pointer when
// returned), but passed in a register
struct Handle {
    uint32_t id;
    Handle(uint32_t i) : id(i) {}
    Handle(Handle &&o) : id(o.id) {}
};

// 4 bytes, a defaulted move constructor (so no copy constructor): trivial for the call
struct HandleD {
    uint32_t id;
    HandleD(uint32_t i) : id(i) {}
    HandleD(HandleD &&) = default;
};

// 4 bytes, a defaulted copy constructor: trivial
struct HandleC {
    uint32_t id;
    HandleC(uint32_t i) : id(i) {}
    HandleC(const HandleC &) = default;
};

// 4 bytes, only a destructor: the implicit copy constructor is trivial
struct WithDtor {
    uint32_t id;
    WithDtor(uint32_t i) : id(i) {}
    ~WithDtor() { id = 0; }
};

// 4 bytes with a copy constructor: passed as a pointer to a copy
struct Counted {
    int32_t v;
    Counted(int32_t x) : v(x) {}
    Counted(const Counted &o) : v(o.v + 1000) {}
    ~Counted() { v = -1; }
};

// bitfields: MSVC storage units of 4, 2, 1 and 8 bytes, a 64-bit unit with a field across bit 32
struct Bits {
    uint32_t a : 3;
    uint32_t b : 5;
    uint32_t : 0;
    uint16_t c : 4;
    uint8_t d;
    uint64_t e : 40;
    uint64_t f : 24;
    uint64_t g : 30;
    uint64_t h : 34;
    bool flag : 1;
};

#pragma pack(push, 4)
struct Packed {
    int8_t a;
    int64_t b;
    int16_t c;
};
#pragma pack(pop)

// an anonymous union with an anonymous struct inside: overlapping members
struct WithUnion {
    int32_t kind;
    union {
        int32_t i;
        float f;
        struct {
            int16_t lo, hi;
        };
    };
    double d;
};

enum class Color : uint8_t { Red = 1, Green = 2, Blue = 4 };

struct FfxError {
    int32_t code;
};

class Base {
public:
    virtual ~Base() { base = -1; }
    virtual int32_t Value() const { return base; }
    virtual int32_t Add(int32_t x) {
        base += x;
        return base;
    }
    int32_t base = 10;
};

class Other {
public:
    virtual ~Other() {}
    virtual int32_t Other1() { return o + 1; }
    int32_t o = 5;
};

// two vfptrs (+0, +16); Other1 overrides the secondary base's method (this adjusted by 16)
class Derived : public Base, public Other {
public:
    int32_t Value() const override { return base * 2 + own; }
    int32_t Other1() override { return o * 100 + own; }
    virtual float Scale(float f, double g) { return (float)(f * own + g); }
    EXP Vec2 GetVec() const { return Vec2{(float)own, 2.5f}; }
    EXP Big GetBig(int32_t k) const { return Big{k, own, 3}; }
    EXP static Vec2 MakeVec(float x, float y) { return Vec2{x, y}; }
    EXP static Handle MakeHandle(uint32_t id) { return Handle(id); }
    int32_t own = 7;
};

API Vec2 ffx_vec(float x, float y) { return Vec2{x * 2, y * 3}; }
API Big ffx_big(int64_t a) { return Big{a, a + 1, a + 2}; }
EXP Handle ffx_handle(uint32_t id) { return Handle(id + 1); }
EXP int32_t ffx_take_handle(Handle h) { return (int32_t)h.id * 10; }
EXP int32_t ffx_take_counted(Counted c) { return c.v; }
EXP int32_t ffx_take_handle_d(HandleD h) { return (int32_t)h.id * 10; }
EXP int32_t ffx_take_handle_c(HandleC h) { return (int32_t)h.id * 10; }
EXP int32_t ffx_take_with_dtor(WithDtor h) { return (int32_t)h.id * 10; }
EXP int64_t ffx_take_big(Big b) { return b.a + b.b * 10 + b.c * 100; }
EXP int64_t ffx_take_vec(Vec2 v) { return (int64_t)(v.x * 10 + v.y); }
EXP double ffx_mix(int32_t a, float b, int64_t c, double d, float e, int32_t f) { return a + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000; }
API int32_t ffx_sum(int32_t n, ...) {
    // varargs, read the MSVC x64 way: every argument in an 8-byte slot
    va_list ap;
    va_start(ap, n);
    int32_t s = 0;
    for (int32_t i = 0; i < n; ++i) {
        s += va_arg(ap, int32_t);
    }
    va_end(ap);
    return s;
}
EXP int64_t ffx_bits(const Bits *b) { return b->a + b->b * 10 + b->c * 100 + b->d * 1000 + (int64_t)b->e * 10000 + (int64_t)b->h * 7 + (b->flag ? 1 : 0); }
EXP int32_t ffx_union(const WithUnion *u) { return u->kind == 0 ? u->i : u->hi; }
EXP int64_t ffx_packed(const Packed *p) { return p->a + p->b * 10 + p->c * 100; }
EXP Color ffx_color(Color c) { return (Color)((uint8_t)c << 1); }
EXP Derived *ffx_new_derived() { return new Derived(); }
EXP void ffx_delete(Base *b) { delete b; }
EXP int32_t ffx_call_value(const Base *b) { return b->Value(); }
EXP int32_t ffx_throw_if(int32_t x) {
    if (x == 42) {
        throw FfxError{x};
    }
    return x + 1;
}
EXP int32_t ffx_catch(int32_t x) {
    try {
        return ffx_throw_if(x);
    } catch (const FfxError &e) {
        return -e.code;
    }
}
