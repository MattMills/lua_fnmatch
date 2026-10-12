/* fixture.c : a small x64 DLL for the lua_fnmatch tests.
 *
 * Built twice by build_fixtures.sh: fixture_v1.dll (the reference build, with a PDB and a .sig
 * file) and fixture_v2.dll (-DFIXTURE_V2, the "next patch"): new functions move everything,
 * ship_calc_regen uses another constant, legacy_checksum is gone, and a new function shares a
 * string with fixture_log. The functions give every signature kind something to work with:
 * strings, wide and indirect strings, float constants, immediates, imports, exports, a vtable, a
 * table of code pointers, a thunk, shared globals, function pointers and a call graph.
 */

#define NOINLINE __declspec(noinline)
#define EXPORT __declspec(dllexport) NOINLINE
#define IMPORT __declspec(dllimport)

IMPORT int lstrlenA(const char *s);
IMPORT int lstrlenW(const unsigned short *s);
IMPORT unsigned long GetTickCount(void);
IMPORT void Sleep(unsigned long ms);
IMPORT unsigned long GetCurrentProcessId(void);
IMPORT void OutputDebugStringA(const char *s);

typedef struct Ship
{
    int hull;
    int armor;
    int shield;
    float regen;
    int state;
} Ship;

/* floating point without a C runtime */
int _fltused;

int g_counter;
int g_mode;
int g_events;
float g_scale = 1.0f;

#if defined(FIXTURE_V2)
/* new in v2: everything after them moves */
NOINLINE int patch_notes_count(int x)
{
    OutputDebugStringA("fixture: patch 2 notes");
    return x * 3 + lstrlenA("fixture: v2");
}

NOINLINE int patch_warning(int level)
{
    if (level > 2) {
        OutputDebugStringA("fixture: warning"); /* also in fixture_log */
    }
    return level + g_mode;
}
#endif

NOINLINE int ship_hull(const Ship *s)
{
    return s->hull;
}

NOINLINE float ship_calc_regen(const Ship *s)
{
#if defined(FIXTURE_V2)
    return s->regen * 1.5f + (float)s->shield * 0.015625f;
#else
    return s->regen * 1.2345f + (float)s->shield * 0.015625f;
#endif
}

NOINLINE int ship_damage(Ship *s, int amount)
{
    int absorbed = amount < s->shield ? amount : s->shield;
    s->shield -= absorbed;
    amount -= absorbed;
    if (amount > s->armor) {
        s->hull -= amount - s->armor;
        g_counter += 1;
    }
    if (ship_hull(s) <= 0) {
        s->state = 3;
        g_events += 7;
    }
    return amount;
}

/* a one-instruction thunk (jmp ship_damage) */
NOINLINE int ship_damage_thunk(Ship *s, int amount)
{
    return ship_damage(s, amount);
}

NOINLINE int ship_armor_a(const Ship *s)
{
    return s->armor * 2 + 1;
}

/* the same code as ship_armor_a: its code signatures are not unique */
NOINLINE int ship_armor_b(const Ship *s)
{
    return s->armor * 2 + 1;
}

static int vt_hull(const Ship *s)
{
    return s->hull + s->armor;
}

static float vt_regen(const Ship *s)
{
    return ship_calc_regen(s) * g_scale;
}

static int vt_damage(Ship *s, int amount)
{
    g_events += 1;
    return ship_damage(s, amount * 2);
}

static void vt_reset(Ship *s)
{
    s->hull = 1000;
    s->armor = 250;
    s->shield = 500;
    s->state = 0;
}

typedef struct ShipVtbl
{
    int (*hull)(const Ship *);
    float (*regen)(const Ship *);
    int (*damage)(Ship *, int);
    void (*reset)(Ship *);
} ShipVtbl;

static const ShipVtbl ship_vtbl = {vt_hull, vt_regen, vt_damage, vt_reset};

NOINLINE const ShipVtbl *ship_construct(Ship *s)
{
    s->regen = 2.5f;
    vt_reset(s);
    return &ship_vtbl;
}

NOINLINE int vtable_round(Ship *s)
{
    const ShipVtbl *vt = ship_construct(s);
    int total = vt->hull(s);
    total += vt->damage(s, 40);
    total += (int)vt->regen(s);
    return total;
}

static const char *const ship_classes[] = {"corvette", "destroyer", "cruiser", "battleship", "titan"};

NOINLINE int ship_class_length(int i)
{
    return lstrlenA(ship_classes[i % 5]);
}

NOINLINE int wide_title_length(void)
{
    return lstrlenW((const unsigned short *)L"Fixture Window Title");
}

NOINLINE unsigned int mix_hash(unsigned int x)
{
    x ^= x >> 16;
    x *= 0x5bd1e995u;
    x ^= x >> 13;
    x *= 0x7feb352du;
    return x ^ (x >> 15);
}

NOINLINE int classify(int x)
{
    switch (x) {
    case 0: return ship_class_length(1) + 11;
    case 1: return mix_hash(12) + 3;
    case 2: return wide_title_length() * 13;
    case 3: return g_counter + 14;
    case 4: return g_mode * 15;
    case 5: return (int)GetCurrentProcessId() + 16;
    case 6: return g_events - 17;
    case 7: return ship_class_length(3) + 18;
    default: return -1;
    }
}

typedef int (*event_handler)(int);

static event_handler handlers[4];

NOINLINE void register_handler(int slot, event_handler h)
{
    handlers[slot & 3] = h;
}

NOINLINE int on_ship_destroyed(int id)
{
    g_events += id;
    return id * 31 + 0x1234;
}

NOINLINE int on_war_declared(int id)
{
    g_mode = id;
    return mix_hash((unsigned int)id) & 0xffff;
}

NOINLINE int dispatch(int slot, int arg)
{
    event_handler h = handlers[slot & 3];
    return h != 0 ? h(arg) : 0;
}

/* a table of code pointers in data */
static int (*const startup_steps[])(int) = {on_ship_destroyed, on_war_declared, classify};

NOINLINE int run_startup(int arg)
{
    int total = 0;
    for (int i = 0; i < 3; ++i) {
        total += startup_steps[i](arg + i);
    }
    return total;
}

#if !defined(FIXTURE_V2)
/* removed in v2 */
NOINLINE unsigned int legacy_checksum(const unsigned char *p, int n)
{
    unsigned int a = 1, b = 0;
    for (int i = 0; i < n; ++i) {
        a = (a + p[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}
#endif

EXPORT int fixture_log(int level)
{
    if (level > 2) {
        OutputDebugStringA("fixture: warning");
    }
    OutputDebugStringA("fixture: log line");
    return level + 1;
}

EXPORT unsigned long fixture_tick(void)
{
    unsigned long t = GetTickCount();
    Sleep(0);
    return mix_hash((unsigned int)t) ^ 0xdeadbeefu;
}

EXPORT int fixture_update(Ship *s, int turn)
{
    int r = 0;
    register_handler(0, on_ship_destroyed);
    register_handler(1, on_war_declared);
    r += ship_damage_thunk(s, turn * 5);
    r += (int)ship_calc_regen(s);
    r += ship_armor_a(s) + ship_armor_b(s);
    r += dispatch(turn, s->hull);
    r += vtable_round(s);
    r += classify(turn & 7);
    r += run_startup(turn);
    r += ship_class_length(turn) + wide_title_length();
#if !defined(FIXTURE_V2)
    r += (int)legacy_checksum((const unsigned char *)s, (int)sizeof(Ship));
#else
    r += patch_notes_count(turn) + patch_warning(turn);
#endif
    return r + fixture_log(turn);
}
