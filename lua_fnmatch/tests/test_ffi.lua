-- test_ffi.lua: fnmatch.ffi against the declarations of tests/fixtures/ffi (an MSVC-built DLL,
-- ffi_fixture.cpp, and the module stellar-fnmatch cdef generated from its PDB).
--
--   lua test_ffi.lua <module dir or ""> <fixtures dir>
--
-- Everywhere: the layouts under this LuaJIT, the ABI rules recorded per function, the type
-- registry, bundles with typed functions. On Windows: every function of the DLL called through
-- its declaration (results computed by the C++ code), virtual calls, the deleting destructor,
-- and a C++ exception thrown through an FFI call. Without the LuaJIT FFI: the errors.

local module_dir, fixtures = ...
if module_dir ~= nil and module_dir ~= "" then
    package.cpath = module_dir .. "/?.so;" .. module_dir .. "/?.dll;" .. package.cpath
end
local fnmatch = require("fnmatch")
fixtures = (fixtures and fixtures ~= "") and fixtures or "fixtures"
local dir = fixtures .. "/ffi/"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end
local function eq(a, b, what)
    check(a == b, string.format("%s: %s, expected %s", what, tostring(a), tostring(b)))
end
local function errors(f, pattern, what)
    local ok, err = pcall(f)
    check(not ok and tostring(err):find(pattern, 1, true) ~= nil, what .. ": " .. tostring(err))
end

local fx = fnmatch.ffi
check(type(fx) == "table" and type(fx.load) == "function", "fnmatch.ffi")

if not fx.available then
    errors(function() fx.load(dir .. "ffi_fixture.ffi.lua") end, "LuaJIT FFI is not available", "load without the FFI")
    print(string.format("test_ffi: %d checks, %d failures (no LuaJIT FFI in %s: only the errors)", checks, failures, _VERSION))
    if failures > 0 then
        error(failures .. " check(s) failed", 0)
    end
    return
end

local ffi = require("ffi")
local b = assert(fx.load(dir .. "ffi_fixture.ffi.lua"))
local nb, err = fx.load(dir .. "missing.ffi.lua")
check(nb == nil and err:find("fnmatch.ffi") ~= nil, "a missing module")
errors(function() fx.load({}) end, "not a module generated", "a table that is not a module")

-- layouts: every type, every member, as the PDB says
for c, t in pairs(b.module.types) do
    local ct = b:type(c)
    eq(ffi.sizeof(ct), t.size, "sizeof " .. c)
    for _, f in ipairs(t.fields or {}) do
        if f.unit then
            eq(ffi.offsetof(ct, f.unit), f[2], "unit of " .. c .. "." .. f[1])
        else
            local o, p, n = ffi.offsetof(ct, f[1])
            if f[4] then
                eq(o * 8 + p, f[2] * 8 + f[4], "bit position of " .. c .. "." .. f[1])
                eq(n, f[5], "bits of " .. c .. "." .. f[1])
            else
                eq(o, f[2], "offsetof " .. c .. "." .. f[1])
            end
        end
    end
end
check(b:info("Packed").packed == true, "Packed is declared packed")
eq(b:cname("Color"), "Color", "cname of an enum")
local color = b:enum("Color")
eq(color.Red, 1, "enum value")
eq(color.Blue, 4, "enum value")
eq(color[2], "Green", "enum name")
errors(function() b:enum("Vec2") end, "is not an enum", "enum of a struct")
errors(function() b:type("NoSuchType") end, "unknown type", "unknown type")

-- the ABI rules, as declared
local function decl(name, which)
    return assert(b:func(name, which)).decl
end
eq(decl("ffx_vec"), "Vec2 (*)(float, float)", "POD of 8 bytes returned in RAX")
eq(decl("ffx_big"), "Big *(*)(Big *, int64_t)", "large result: hidden pointer first")
eq(decl("ffx_handle"), "Handle *(*)(Handle *, uint32_t)", "non-POD result: hidden pointer first")
eq(decl("Derived::GetVec"), "Vec2 *(*)(const Derived *, Vec2 *)", "method result: hidden pointer after this")
eq(decl("Derived::MakeVec"), "Vec2 (*)(float, float)", "static method: C rules")
eq(decl("ffx_take_handle"), "int32_t (*)(Handle *)", "user-provided move constructor, no copy constructor: by address (from the code)")
eq(decl("ffx_take_handle_d"), "int32_t (*)(HandleD *)", "defaulted move constructor, no copy constructor: by address (from the code)")
eq(decl("ffx_take_handle_c"), "int32_t (*)(HandleC)", "defaulted copy constructor: in a register")
eq(decl("ffx_take_with_dtor"), "int32_t (*)(WithDtor)", "a destructor only: in a register")
eq(decl("ffx_take_counted"), "int32_t (*)(Counted *)", "class with a copy constructor: pointer to a copy")
eq(decl("ffx_take_big"), "int64_t (*)(Big *)", "large class: pointer to a copy")
eq(decl("Derived::Other1"), "int32_t (*)(Other *)", "override through the second base: this is that base")
eq(b:func("Derived::Other1").this_adjust, 16, "this adjustment")
eq(b:func("Derived::Other1").virtual.vfptr, 16, "vfptr of the second base")
eq(b:func("Derived::Scale").virtual.slot, 3, "a new virtual after the destructor, Value and Add")
eq(b:func("Derived::`scalar deleting destructor'").virtual.slot, 0, "deleting destructor slot")
eq(b:func("ffx_throw_if").throws, "yes", "throws")
eq(b:func("ffx_vec").throws, "no", "does not throw")
check(b:func("ffx_new_derived").via:find("alloc", 1, true) ~= nil, "operator new: alloc")
local _, ambiguous = b:func("nothing")
check(ambiguous ~= nil, "func of an unknown name")
errors(function() b:fn("nothing", 0) end, "no declaration", "fn of an unknown name")
for name, list in pairs(b.module.functions) do
    for i = 1, #list do
        check(b:fntype(name, i) ~= nil, "declaration of " .. name)
    end
end

-- bitfields: C fields and the accessors of the 64-bit units
local bits = ffi.new("Bits")
bits.a, bits.b, bits.c, bits.d, bits.flag = 5, 17, 9, 200, true
b:setbits(bits, "Bits", "e", 0x12345678AB)
b:setbits(bits, "Bits", "f", 0xABCDE)
b:setbits(bits, "Bits", "g", 0x2AAAAAAA)
b:setbits(bits, "Bits", "h", 0x355555555)
eq(b:getbits(bits, "Bits", "e"), 0x12345678AB, "64-bit unit field e")
eq(b:getbits(bits, "Bits", "f"), 0xABCDE, "64-bit unit field f")
eq(b:getbits(bits, "Bits", "g"), 0x2AAAAAAA, "64-bit unit field g")
eq(b:getbits(bits, "Bits", "h"), 0x355555555, "64-bit unit field h across bit 32")
eq(bits.a, 5, "bitfield a")
eq(bits.b, 17, "bitfield b")

-- casts to base subobjects
local raw = ffi.new("uint8_t[40]")
local dp = ffi.cast(b:ptr("Derived"), raw)
eq(tonumber(ffi.cast("uintptr_t", b:cast(dp, "Other")) - ffi.cast("uintptr_t", raw)), 16, "cast to the second base")
eq(tonumber(ffi.cast("uintptr_t", b:cast(dp, "Base")) - ffi.cast("uintptr_t", raw)), 0, "cast to the first base")
errors(function() b:cast(dp, "Vec2") end, "is not a base", "cast to a class that is not a base")

-- a second module of another build cannot redefine a type
local copy = {}
for k, v in pairs(b.module) do
    copy[k] = v
end
copy.pdb = { guid = "other", age = 1 }
local b2 = fx.load(copy)
errors(function() b2:type("Vec2") end, "already declared by another module", "a type declared by another module")

-- bundles with typed functions
do
    local image = assert(fnmatch.file(dir .. "ffi_fixture.dll", { pdb = dir .. "ffi_fixture.pdb" }))
    local bundle = fnmatch.bundle(image, { ffi = b })
    local got = {}
    for _, name in ipairs({ "ffx_vec", "ffx_mix", "Derived::GetBig" }) do
        local addr = image:functions_named(name)[1].address
        bundle:register({
            name = name,
            signatures = image:signatures(addr),
            callback = function(address, entry, fn)
                got[name] = { address = address, fn = fn, declaration = entry.declaration }
            end,
        })
    end
    errors(function() bundle:register({ name = "nothing", signature = "pic:1" }) end, "no declaration of nothing", "a bundle entry without a declaration")
    local report = bundle:run()
    check(report.ok, "bundle with typed functions: " .. tostring(report.error))
    for _, name in ipairs({ "ffx_vec", "ffx_mix", "Derived::GetBig" }) do
        local g = got[name]
        check(g ~= nil and type(g.fn) == "cdata", "typed function of " .. name)
        if g then
            eq(tonumber(ffi.cast("uintptr_t", g.fn)), g.address, "typed function address of " .. name)
            eq(g.declaration.decl, decl(name), "declaration of " .. name)
        end
    end
    image:close()
end

-- calls, on Windows (the fixture is a Windows DLL)
if ffi.os == "Windows" and ffi.arch == "x64" then
    pcall(ffi.cdef, "void *LoadLibraryA(const char *name); int FreeLibrary(void *module);")
    local module = ffi.C.LoadLibraryA(dir .. "ffi_fixture.dll")
    check(module ~= nil, "LoadLibrary of the fixture")
    local base = tonumber(ffi.cast("uintptr_t", module))
    local function fn(name, which, options)
        local d = assert(b:func(name, which))
        return b:fn(name, base + d.rva, which, options)
    end

    local v = fn("ffx_vec")(1.5, 2)
    eq(v.x, 3, "ffx_vec x")
    eq(v.y, 6, "ffx_vec y")
    local big = ffi.new("Big")
    local r = fn("ffx_big")(big, 5)
    check(r == ffi.cast("Big *", big), "hidden pointer returned")
    eq(tonumber(big.a) + tonumber(big.b) * 10 + tonumber(big.c) * 100, 5 + 60 + 700, "ffx_big through the hidden pointer")
    local h = ffi.new("Handle")
    fn("ffx_handle")(h, 41)
    eq(h.id, 42, "non-POD result through the hidden pointer")
    eq(fn("ffx_take_handle")(ffi.new("Handle", 7)), 70, "move-only class by address")
    eq(fn("ffx_take_handle_d")(ffi.new("HandleD", 7)), 70, "defaulted move-only class by address")
    eq(fn("ffx_take_handle_c")(ffi.new("HandleC", 7)), 70, "class with a defaulted copy constructor in a register")
    eq(fn("ffx_take_with_dtor")(ffi.new("WithDtor", 7)), 70, "class with a destructor in a register")
    local counted = ffi.new("Counted", 3)
    eq(fn("ffx_take_counted")(counted), 3, "pointer to a copy")
    eq(counted.v, -1, "the callee destroyed the copy")
    eq(tonumber(fn("ffx_take_big")(ffi.new("Big", 1, 2, 3))), 321, "large class by a pointer to a copy")
    eq(tonumber(fn("ffx_take_vec")(ffi.new("Vec2", 1.5, 2))), 17, "POD of 8 bytes in a register")
    eq(fn("ffx_mix")(1, 2.5, 3, 4.25, 5.5, 6), 1 + 25 + 300 + 4250 + 55000 + 600000, "floats and integers by position, on the stack after four")
    eq(fn("ffx_sum")(3, ffi.new("int32_t", 1), ffi.new("int32_t", 2), ffi.new("int32_t", 3)), 6, "variadic")
    eq(tonumber(fn("ffx_bits")(bits)), 5 + 170 + 900 + 200000 + 0x12345678AB * 10000 + 0x355555555 * 7 + 1, "bitfields read by the C++ code")
    local u = ffi.new("WithUnion")
    u.kind, u.lo, u.hi = 1, 3, 77
    eq(fn("ffx_union")(u), 77, "anonymous union member")
    local pk = ffi.new("Packed")
    pk.a, pk.b, pk.c = 1, 2, 3
    eq(tonumber(fn("ffx_packed")(pk)), 321, "packed struct read by the C++ code")
    eq(fn("ffx_color")(color.Green), color.Blue, "enum by value")

    local obj = fn("ffx_new_derived")()
    eq(b:vcall(obj, "Derived::Value"), 27, "virtual call")
    eq(b:vcall(obj, "Base::Add", 5), 15, "virtual call with an argument")
    eq(b:vcall(obj, "Derived::Other1"), 507, "virtual call through the second vfptr")
    eq(b:vcall(obj, "Derived::Scale", 2, 0.5), 14.5, "virtual call with float and double")
    eq(fn("Derived::Other1")(b:cast(obj, "Other")), 507, "direct call with the adjusted this")
    eq(fn("Derived::Value")(obj), 37, "direct call")
    local out = ffi.new("Vec2")
    fn("Derived::GetVec")(obj, out)
    eq(out.x, 7, "method result through the hidden pointer")
    eq(out.y, 2.5, "method result through the hidden pointer")
    local ob = ffi.new("Big")
    fn("Derived::GetBig")(obj, ob, 9)
    eq(tonumber(ob.a) * 100 + tonumber(ob.b) * 10 + tonumber(ob.c), 973, "method result with an argument after the hidden pointer")
    local mv = fn("Derived::MakeVec")(1, 2)
    eq(mv.x + mv.y * 10, 21, "static method returning a POD in RAX")
    local mh = ffi.new("Handle")
    fn("Derived::MakeHandle")(mh, 5)
    eq(mh.id, 5, "static method returning a non-POD through a hidden pointer")
    eq(fn("ffx_call_value")(b:cast(obj, "Base")), 37, "the C++ code's own virtual call")
    local del, this = b:vfn(obj, "Derived::`scalar deleting destructor'")
    del(this, 1) -- frees the object

    -- C++ exceptions through FFI calls (interpreted: caught by pcall as "C++ exception")
    local throw = fn("ffx_throw_if")
    eq(throw(1), 2, "no throw")
    local ok, e = pcall(throw, 42)
    check(not ok and tostring(e):find("C++ exception", 1, true), "a C++ exception through an FFI call: " .. tostring(e))
    eq(fn("ffx_catch")(42), -42, "caught inside the C++ code")
    local protected = fn("ffx_throw_if", nil, { protect = true })
    check(type(protected) == "function", "protect wraps")
    local hits = 0
    for i = 1, 300 do
        local good, res = pcall(protected, i % 100 == 42 and 42 or i)
        if not good then
            hits = hits + 1
        else
            eq(res, i + 1, "protected call in a loop")
        end
    end
    eq(hits, 3, "C++ exceptions from a protected function in a hot loop")
    ffi.C.FreeLibrary(module)
    print("test_ffi: called the fixture on Windows")
end

print(string.format("test_ffi: %d checks, %d failures", checks, failures))
if failures > 0 then
    error(failures .. " check(s) failed", 0)
end
