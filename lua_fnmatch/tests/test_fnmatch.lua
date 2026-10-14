-- test_fnmatch.lua : test suite for the fnmatch Lua module.
--
-- Usage: <lua> test_fnmatch.lua [module directory] [fixtures directory]
--
-- Runs on LuaJIT and Lua 5.1 - 5.4. The fixtures (fixtures/build_fixtures.sh) are two builds of a
-- small x64 DLL: fixture_v1 is the reference (with its PDB and the .sig file stellar-fnmatch
-- wrote for it), fixture_v2 the next "patch", where functions were added, changed and removed and
-- everything moved. Its PDB is only used to check answers. On Windows with the LuaJIT FFI,
-- fixture_v2.dll is also loaded to test modules of this process.

local module_dir, fixtures = ...
if module_dir and module_dir ~= "" then
    package.cpath = module_dir .. "/?.so;" .. module_dir .. "/?.dll;" .. package.cpath
end
fixtures = (fixtures and fixtures ~= "") and fixtures or "fixtures"

local fn = require("fnmatch")
local has_ffi, ffi = pcall(require, "ffi")

local V1 = fixtures .. "/fixture_v1.dll"
local PDB1 = fixtures .. "/fixture_v1.pdb"
local SIG1 = fixtures .. "/fixture_v1.sig"
local V2 = fixtures .. "/fixture_v2.dll"
local PDB2 = fixtures .. "/fixture_v2.pdb"

--------------------------------------------------
-- tiny test framework
--

local tests = {}

local function test(name, body)
    tests[#tests + 1] = { name = name, fn = body }
end

local function fail(message, level)
    error(message, (level or 1) + 1)
end

local function check(condition, message)
    if not condition then
        fail(message or "check failed", 2)
    end
end

-- addresses do not fit string.format("%x") on every Lua version
local function hex(n)
    if type(n) ~= "number" then
        return tostring(n)
    end
    local digits, s = "0123456789abcdef", ""
    repeat
        local d = n % 16
        s = digits:sub(d + 1, d + 1) .. s
        n = math.floor((n - d) / 16)
    until n == 0
    return "0x" .. s
end

local function show(value)
    return type(value) == "number" and hex(value) or tostring(value)
end

local function eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s", message or "values differ", show(expected), show(actual)), 2)
    end
end

local function list_eq(actual, expected, message)
    local function text(list)
        local parts = {}
        for i = 1, math.min(#list, 16) do
            parts[i] = show(list[i])
        end
        return "{" .. table.concat(parts, ", ") .. (#list > 16 and ", ..." or "") .. "}"
    end
    local same = #actual == #expected
    for i = 1, #expected do
        same = same and actual[i] == expected[i]
    end
    if not same then
        fail(string.format("%s: expected %s (%d), got %s (%d)", message or "lists differ",
            text(expected), #expected, text(actual), #actual), 2)
    end
end

local function raises(body, pattern)
    local ok, err = pcall(body)
    if ok then
        fail("expected an error" .. (pattern and (" containing '" .. pattern .. "'") or ""), 2)
    end
    if pattern and not tostring(err):find(pattern, 1, true) then
        fail(string.format("error '%s' does not contain '%s'", tostring(err), pattern), 2)
    end
    return err
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

--------------------------------------------------
-- fixtures
--

local ref = assert(fn.file(V1, { pdb = PDB1 }))   -- the reference build, with names
local truth = assert(fn.file(V2, { pdb = PDB2 })) -- names of the new build, to check answers

-- a fresh image of the new build, without names (bundles give names to their images)
local function target(options)
    return assert(fn.file(V2, options))
end

local tgt = target()

-- address of the only function with this name
local function addr(image, name)
    local found = image:functions_named(name)
    if #found ~= 1 then
        fail(string.format("%d functions named %s", #found, name), 2)
    end
    return found[1].address
end

-- the reference build's unique signatures of a function, optionally only some kinds
local function ref_sigs(name, kind_pattern)
    local out = {}
    for _, sig in ipairs(ref:signatures(addr(ref, name))) do
        if kind_pattern == nil or fn.signature.kind(sig):find(kind_pattern) then
            out[#out + 1] = sig
        end
    end
    return out
end

-- the shared code signature of ship_armor_a and ship_armor_b (same code)
local function armor_pic()
    for _, sig in ipairs(ref:signatures(addr(ref, "ship_armor_a"), true)) do
        if fn.signature.kind(sig) == "pic" then
            return sig
        end
    end
end

-- the bytes of a float, for constant() (string.pack is not in Lua 5.1)
local float_bytes = {
    [1.2345] = "\025\004\158\063",
    [1.5] = "\000\000\192\063",
    [0.015625] = "\000\000\128\060",
}

--------------------------------------------------
-- module
--

test("module fields", function()
    check(fn._VERSION:find("^lua_fnmatch %d+%.%d+%.%d+$"), fn._VERSION)
    check(type(fn.fnmatch_version) == "string" and fn.fnmatch_version:find("^%d+%.%d+"), tostring(fn.fnmatch_version))
    check(fn.platform == "windows" or fn.platform == "linux")
    check(fn.hardware_concurrency >= 1)
    check(type(fn.bundle) == "function")
    eq(#fn.kinds, 41, "17 code, data and structure kinds, 12 anchored and 12 symbol relations")
    eq(fn.kinds[1], "exact")
    eq(fn.kinds[2], "pic")
    eq(fn.kinds[17], "layout3")
    eq(fn.kinds[18], "a_callee_ord")
    eq(fn.kinds[41], "s_fnptr")
end)

--------------------------------------------------
-- signatures
--

test("signature text form", function()
    eq(fn.signature("pic:1"), "pic:000000000000001")
    eq(fn.signature("  pic:0x2a  "), "pic:00000000000002a")
    eq(fn.signature("0400000000000001"), "pic:000000000000001")
    eq(fn.signature("0x0400000000000001"), "pic:000000000000001")
    eq(fn.signature("s_vtslot:3ffffffffffffff"), "s_vtslot:3ffffffffffffff")
    eq(fn.signature.parse("exact:abc"), "exact:000000000000abc")
    eq(fn.signature.kind("s_vtslot:5"), "s_vtslot")
    eq(fn.signature.kind("0000000000000005"), "exact")
    for _, kind in ipairs(fn.kinds) do
        eq(fn.signature.kind(fn.signature(kind .. ":1")), kind)
    end
end)

test("invalid signatures", function()
    for _, text in ipairs({ "nope:1", "pic:", "pic:xyz", "pic:1000000000000000", "pic:400000000000000",
        "k17:1", "0x44", "4400000000000000", "", "pic 1" }) do
        local sig, message = fn.signature.parse(text)
        eq(sig, nil, text)
        check(type(message) == "string" and #message > 0, text)
    end
    raises(function() fn.signature("nope:1") end, "unknown signature kind 'nope'")
    raises(function() fn.signature("pic:400000000000000") end, "more than 58 bits")
    raises(function() fn.signature(42) end, "signature string expected")
    raises(function() fn.signature("pic:1\0") end, "zero byte")
    raises(function() fn.signature.kind({}) end, "signature string expected")
end)

test("signatures from facts", function()
    local s = fn.signature.string("fixture: log line")
    eq(fn.signature.kind(s), "str")
    eq(fn.signature.string("fixture: log line"), s, "deterministic")
    check(fn.signature.string("fixture: log line!") ~= s)
    eq(fn.signature.kind(fn.signature.indirect_string("titan")), "istr")
    eq(fn.signature.wide_string("Fixture Window Title"), fn.signature.string('L"Fixture Window Title'))
    eq(fn.signature.kind(fn.signature.export("fixture_update")), "export")
    eq(fn.signature.kind(fn.signature.immediate(0x5bd1e995)), "imm")
    eq(fn.signature.immediate(0x5bd1e995), fn.signature.immediate("5bd1e995"))
    eq(fn.signature.immediate(-1), fn.signature.immediate("ffffffffffffffff"))
    eq(fn.signature.immediate(-2), fn.signature.immediate("0xfffffffffffffffe"))
    eq(fn.signature.kind(fn.signature.constant(float_bytes[1.5])), "const")
    eq(fn.signature.kind(fn.signature.thunk_to("ship_damage")), "s_thunk")
    -- names are normalized like the PDB names: lambda and anonymous namespace hashes go
    eq(fn.signature.thunk_to("f::<lambda_0123abcd>::operator()"), fn.signature.thunk_to("f::<lambda>::operator()"))
    raises(function() fn.signature.constant("") end, "1 to 32 bytes")
    raises(function() fn.signature.constant(string.rep("x", 33)) end, "1 to 32 bytes")
    raises(function() fn.signature.immediate(1.5) end, "integer expected")
    raises(function() fn.signature.immediate("12345678901234567") end, "hex digits expected")
    raises(function() fn.signature.immediate({}) end, "number or hex string expected")
    raises(function() fn.signature.string("\255\254") end, "not UTF-8")
    raises(function() fn.signature.thunk_to("") end, "not a function name")
end)

test("decode", function()
    local i = fn.decode("\72\137\92\36\8") -- mov [rsp+8], rbx
    eq(i.length, 5)
    eq(i.flow, "next")
    eq(i.rip_relative, false)
    eq(i.target, nil)
    eq(i.text, "mov [rsp+8],rbx")
    i = fn.decode("\232\0\0\0\0", 4096) -- call to the next instruction
    eq(i.flow, "call")
    eq(i.target, 4101)
    i = fn.decode("\72\139\5\16\0\0\0", 8192) -- mov rax, [rip+0x10]
    eq(i.rip_relative, true)
    eq(i.target, 8192 + 7 + 16)
    i = fn.decode("\144\195", 16, 2) -- nop; ret: the ret, at 17
    eq(i.flow, "return")
    eq(i.length, 1)
    eq(fn.decode("\235\254", 32).target, 32) -- jmp to itself
    eq(fn.decode("\72"), nil) -- not a whole instruction
    eq(fn.decode("\144", 0, 2), nil) -- past the end
end)

--------------------------------------------------
-- images
--

test("images of files", function()
    eq(#ref, 25)
    eq(ref:count(), 25)
    eq(#tgt, 26)
    check(ref:has_pdb())
    check(not tgt:has_pdb())
    eq(tgt:base(), 0x180000000, "the PE image base")
    check(tgt:md5():find("^%x+$") and #tgt:md5() == 32)
    eq(tgt:md5(), truth:md5())
    check(tgt:md5() ~= ref:md5())
    check(tgt:path():find("fixture_v2.dll", 1, true))
    check(tostring(tgt):find("fnmatch.image: .*fixture_v2.dll %(26 functions%)"), tostring(tgt))
    check(tgt:signature_count() > 500)
end)

test("functions and their names", function()
    local first = ref[1]
    eq(first.index, 1)
    eq(first.address, ref:base() + first.rva)
    check(first.end_address > first.address and first.size > 0 and first.instructions > 0)
    eq(ref[0], nil)
    eq(ref[26], nil)
    eq(ref[1.5], nil)
    local previous = 0
    for i = 1, #ref do
        local f = ref[i]
        eq(f.index, i)
        check(f.address > previous, "address order")
        previous = f.address
        eq(#f.names, 1)
        eq(ref:function_at(f.address).index, i)
        eq(ref:function_at(f.address + f.size - 1).index, i)
    end
    eq(ref:function_at(ref:base()), nil, "the PE header")
    eq(ref:function_at(0), nil)

    local damage = ref:functions_named("ship_damage")
    eq(#damage, 1)
    list_eq(damage[1].names, { "ship_damage" })
    eq(#ref:functions_named("no_such_function"), 0)
    eq(#tgt:functions_named("ship_damage"), 0, "no names without a PDB")
    eq(#tgt[1].names, 0)
    eq(#ref:functions_named("legacy_checksum"), 1)
    eq(#truth:functions_named("legacy_checksum"), 0, "removed in v2")
    eq(#truth:functions_named("patch_warning"), 1, "new in v2")
end)

test("image options and errors", function()
    local moved = target({ base = 0x10000, threads = 1 })
    eq(moved:base(), 0x10000)
    eq(moved[1].address, 0x10000 + tgt[1].rva)
    local sig = ref_sigs("ship_damage", "^pic$")[1]
    list_eq(moved:find(sig), { tgt:find(sig)[1] - tgt:base() + 0x10000 })

    local image, message = fn.file(fixtures .. "/no_such.dll")
    eq(image, nil)
    check(message:find("no_such.dll", 1, true), message)
    image, message = fn.file(fixtures .. "/fixture.c")
    eq(image, nil)
    check(message:find("not an MZ file", 1, true), message)
    image, message = fn.file(V2, { pdb = fixtures .. "/no_such.pdb" })
    eq(image, nil)
    check(message:find("no_such.pdb", 1, true), message)
    image, message = fn.image("MZ but not really")
    eq(image, nil)
    check(type(message) == "string")

    raises(function() fn.file(V2, { pbd = PDB2 }) end, "unknown option 'pbd'")
    raises(function() fn.file(V2, { threads = -1 }) end, "threads")
    raises(function() fn.file(V2, 5) end, "options table expected")
    raises(function() fn.file() end, "path expected")
    raises(function() fn.module(V2, { base = 1 }) end, "unknown option 'base'")
end)

test("images of strings", function()
    local f = assert(io.open(V2, "rb"))
    local contents = f:read("*a")
    f:close()
    local image = assert(fn.image(contents, { name = "v2 in memory" }))
    eq(#image, #tgt)
    eq(image:md5(), tgt:md5())
    eq(image:path(), "v2 in memory")
    for i = 1, #tgt do
        list_eq(image:signatures(image[i].address, true), tgt:signatures(tgt[i].address, true))
    end
    local named = assert(fn.image(contents, { pdb = PDB2 }))
    eq(named[3].names[1], truth[3].names[1])
end)

test("signatures(): unique, or all", function()
    for i = 1, #ref do
        local f = ref[i]
        local unique, all = ref:signatures(f.address), ref:signatures(f.address, true)
        check(#unique > 0, f.names[1] .. " has a unique signature")
        check(#all >= #unique)
        for _, sig in ipairs(unique) do
            check(contains(all, sig))
            list_eq(ref:find(sig), { f.address }, sig)
        end
        for _, sig in ipairs(all) do
            check(contains(ref:find(sig), f.address), sig)
        end
    end
    eq(ref:signatures(ref:base()), nil)
end)

test("every signature kind is in the fixtures", function()
    local seen = {}
    for i = 1, #ref do
        for _, sig in ipairs(ref:signatures(ref[i].address, true)) do
            seen[fn.signature.kind(sig)] = true
        end
    end
    for _, kind in ipairs(fn.kinds) do
        check(seen[kind], kind)
    end
end)

test("the image's signatures are those of the sig file", function()
    local sf = assert(fn.sig_file(SIG1))
    eq(#sf, #ref)
    for i = 1, #ref do
        eq(sf[i].rva, ref[i].rva)
        list_eq(sf:signatures(sf[i].rva), ref:signatures(ref[i].address), ref[i].names[1])
    end
end)

test("find: reference signatures in the new build", function()
    -- every signature that is unique in the reference build and carried by one function of the
    -- new build is carried by the right one
    local resolved, kinds = 0, {}
    for i = 1, #ref do
        local name = ref[i].names[1]
        local right = truth:functions_named(name)
        for _, sig in ipairs(ref:signatures(ref[i].address)) do
            local found = tgt:find(sig)
            if #found == 1 then
                eq(#right, 1, sig .. " of " .. name .. " is in v2")
                eq(found[1], right[1].address, sig .. " of " .. name)
                resolved = resolved + 1
                kinds[fn.signature.kind(sig)] = true
            end
        end
    end
    check(resolved > 200, resolved)
    for _, kind in ipairs({ "pic", "mnem", "bagcfg", "block", "str", "strset", "istr", "const", "imm",
        "imports", "export", "callee_shapes", "caller_shapes", "wl1", "layout3", "a_callee_ord",
        "a_caller", "a_vtslot", "a_layout_prev", "a_table_next", "a_global" }) do
        check(kinds[kind], kind .. " resolves")
    end
end)

test("find: changed and removed functions", function()
    -- ship_calc_regen uses another constant in v2: its code shape stays, its constant does not
    list_eq(tgt:find(ref_sigs("ship_calc_regen", "^pic$")), { addr(truth, "ship_calc_regen") })
    eq(#tgt:find(fn.signature.constant(float_bytes[1.2345])), 0)
    list_eq(ref:find(fn.signature.constant(float_bytes[1.2345])), { addr(ref, "ship_calc_regen") })
    list_eq(tgt:find(fn.signature.constant(float_bytes[1.5])), { addr(truth, "ship_calc_regen") })
    list_eq(tgt:find(fn.signature.constant(float_bytes[0.015625])), { addr(truth, "ship_calc_regen") })
    -- legacy_checksum is gone
    for _, sig in ipairs(ref_sigs("legacy_checksum", "^[^as]")) do
        eq(#tgt:find(sig), 0, sig)
    end
end)

test("find: signatures from facts", function()
    list_eq(tgt:find(fn.signature.string("fixture: log line")), { addr(truth, "fixture_log") })
    -- fixture_log and the new patch_warning share a string
    list_eq(ref:find(fn.signature.string("fixture: warning")), { addr(ref, "fixture_log") })
    list_eq(tgt:find(fn.signature.string("fixture: warning")), { addr(truth, "patch_warning"), addr(truth, "fixture_log") })
    list_eq(tgt:find(fn.signature.wide_string("Fixture Window Title")), { addr(truth, "wide_title_length") })
    list_eq(tgt:find(fn.signature.indirect_string("battleship")), { addr(truth, "ship_class_length") })
    list_eq(tgt:find(fn.signature.export("fixture_update")), { addr(truth, "fixture_update") })
    list_eq(tgt:find(fn.signature.immediate(0x7feb352d)), { addr(truth, "mix_hash") })
    list_eq(tgt:find(fn.signature.immediate(0xdeadbeef)), { addr(truth, "fixture_tick") })
    -- add and sub immediates below 0x10000 are not recorded (on_ship_destroyed adds 0x1234)
    eq(#tgt:find(fn.signature.immediate(0x1234)), 0)
    eq(#tgt:find(fn.signature.string("not in the fixture")), 0)
end)

test("find: a list needs all of its signatures", function()
    local log = addr(truth, "fixture_log")
    local warning = fn.signature.string("fixture: warning")
    local line = fn.signature.string("fixture: log line")
    list_eq(tgt:find({ warning }), { addr(truth, "patch_warning"), log })
    list_eq(tgt:find({ warning, line }), { log })
    list_eq(tgt:find({ line, warning, line }), { log })
    eq(#tgt:find({ line, fn.signature.export("fixture_tick") }), 0)
    raises(function() tgt:find({}) end, "empty list of signatures")
    raises(function() tgt:find({ line, 5 }) end, "signature #2: string expected")
    raises(function() tgt:find({ line, "pic:xyz" }) end, "signature #2: bad signature hash")
    raises(function() tgt:find() end, "signature string expected")
end)

test("find: shared signatures", function()
    -- ship_armor_a and ship_armor_b have the same code
    local a, b = addr(ref, "ship_armor_a"), addr(ref, "ship_armor_b")
    local shared = armor_pic()
    check(shared ~= nil)
    check(not contains(ref:signatures(a), shared), "not unique")
    list_eq(ref:find(shared), { a, b })
    list_eq(tgt:find(shared), { addr(truth, "ship_armor_a"), addr(truth, "ship_armor_b") })
end)

test("symbol relations follow the names", function()
    local image = target()
    local callers = ref_sigs("ship_damage", "^s_caller$")
    check(#callers > 0)
    local damage = addr(truth, "ship_damage")
    -- a PDB image has its names
    list_eq(truth:find(callers[1]), { damage })
    -- a stripped image has the names it is given
    eq(#image:find(callers[1]), 0)
    image:set_name(addr(truth, "ship_hull"), "ship_hull")
    list_eq(image:find(callers[1]), { damage })
    list_eq(image:functions_named("ship_hull")[1].names, { "ship_hull" })
    eq(#image:find(fn.signature.thunk_to("ship_damage")), 0)
    image:set_name(damage + 3, "ship_damage") -- any address inside the function
    list_eq(image:find(fn.signature.thunk_to("ship_damage")), { addr(truth, "ship_damage_thunk") })
    image:set_name(addr(truth, "ship_hull"), nil)
    eq(#image:find(callers[1]), 0)
    eq(#image:functions_named("ship_hull"), 0)
    raises(function() image:set_name(image:base(), "x") end, "no function at this address")
    raises(function() image:set_name(damage, "") end, "not a function name")
    raises(function() image:set_name(damage, 5) end, "name expected")
end)

test("cache", function()
    local dir = "fnmatch-test-cache"
    local first = target({ cache = dir })
    local path = dir .. "/" .. first:md5() .. ".fnx"
    local f = io.open(path, "rb")
    check(f ~= nil, path .. " written")
    f:close()
    local second = target({ cache = dir })
    eq(#second, #first)
    for i = 1, #first do
        list_eq(second:signatures(second[i].address, true), first:signatures(first[i].address, true))
    end
    local named = assert(fn.file(V2, { pdb = PDB2, cache = dir }))
    eq(named[3].names[1], truth[3].names[1], "a PDB build has its own cache entry")
    os.remove(path)
    os.remove(dir .. "/" .. first:md5() .. "-pdb.fnx")
end)

test("close", function()
    local image = target()
    image:close()
    image:close()
    eq(tostring(image), "fnmatch.image (closed)")
    raises(function() image:find(fn.signature.export("fixture_tick")) end, "the image is closed")
    raises(function() return image[1] end, "the image is closed")
    raises(function() return #image end, "the image is closed")
    raises(function() image.close(5) end, "fnmatch.image expected")
end)

--------------------------------------------------
-- sig files
--

test("sig file", function()
    local sf = assert(fn.sig_file(SIG1))
    eq(sf:id(), "fixture_v1")
    eq(sf:platform(), "gog")
    eq(sf:md5(), ref:md5())
    eq(type(sf:version()), "string")
    eq(type(sf:build_string()), "string")
    check(sf:signature_count() > 500)
    check(tostring(sf):find("fnmatch.sig_file: fixture_v1 (25 functions)", 1, true), tostring(sf))
    local damage = sf:functions_named("ship_damage")
    eq(#damage, 1)
    eq(damage[1].rva, addr(ref, "ship_damage") - ref:base())
    list_eq(damage[1].names, { "ship_damage" })
    eq(sf:function_at(damage[1].rva + 1).index, damage[1].index)
    eq(sf:function_at(0), nil)
    eq(sf[0], nil)
    eq(sf[#sf + 1], nil)
    list_eq(sf:signatures("ship_damage"), sf:signatures(damage[1].rva))
    for _, sig in ipairs(sf:signatures("ship_damage")) do
        eq(sf:find(sig).index, damage[1].index)
    end
    eq(sf:find("pic:000000000000001"), nil)
    eq(sf:signatures(0), nil)
    raises(function() sf:signatures("no_such_function") end, "0 functions are named 'no_such_function'")

    local missing, message = fn.sig_file(fixtures .. "/no_such.sig")
    eq(missing, nil)
    check(message:find("no_such.sig", 1, true), message)
    missing, message = fn.sig_file(V1)
    eq(missing, nil)
    check(type(message) == "string")

    sf:close()
    eq(tostring(sf), "fnmatch.sig_file (closed)")
    raises(function() sf:find("pic:1") end, "the sig file is closed")
end)

--------------------------------------------------
-- bundles
--

-- An entry for the reference function `name`: its unique signatures that are not symbol relations.
local function spec_of(name, extra)
    local spec = { name = name, signatures = ref_sigs(name, "^[^s]") }
    for k, v in pairs(extra or {}) do
        spec[k] = v
    end
    return spec
end

test("bundle: one analysis per image, callbacks by priority", function()
    local image = target()
    local calls = {}
    local hooks = fn.bundle(image, {
        before = function(report) calls[#calls + 1] = "before:" .. #report.entries end,
        after = function(report) calls[#calls + 1] = "after:" .. tostring(report.ok) end,
    })
    local entries = {}
    for i, name in ipairs({ "ship_damage", "fixture_log", "mix_hash", "vtable_round", "ship_class_length" }) do
        entries[name] = hooks:register(spec_of(name, {
            priority = (i % 2 == 0) and -1 or 0,
            callback = function(address, entry)
                calls[#calls + 1] = entry.name
                eq(address, entry.address)
            end,
        }))
    end
    local report = hooks:run()
    check(report.ok, report.error)
    eq(report.images, 1)
    eq(report.rounds, 1)
    eq(#report.failed, 0)
    eq(#report.skipped, 0)
    list_eq(calls, { "before:5", "fixture_log", "vtable_round", "ship_damage", "mix_hash", "ship_class_length", "after:true" })
    for name, entry in pairs(entries) do
        check(entry.found, name)
        eq(entry.address, addr(truth, name), name)
        list_eq(entry.matches, { entry.address })
        list_eq(entry.functions, { entry.address })
        eq(entry.signature, entry.signatures[entry.alternative])
        eq(entry.image, image)
        eq(entry.error, nil)
        -- found entries name their function
        list_eq(image:functions_named(name)[1].names, { name })
    end
    check(tostring(hooks):find("5 entries, ran", 1, true))
end)

test("bundle: alternatives, count and offset", function()
    local hooks = fn.bundle(target())
    local log = fn.signature.string("fixture: log line")
    local warning = fn.signature.string("fixture: warning")
    -- the first alternative carried by exactly one function wins
    local first = hooks:register({ name = "fixture_log", signatures = { warning, { warning, log }, log } })
    local pair = hooks:register({ signature = armor_pic(), count = 2, offset = 4 })
    local any = hooks:register({ signature = fn.signature.string("not in the fixture"), count = false })
    local none = hooks:register({ signature = fn.signature.string("not in the fixture"), count = 0 })
    local report = hooks:run()
    check(report.ok, report.error)
    eq(first.alternative, 2)
    list_eq(first.signature, { warning, log })
    eq(first.address, addr(truth, "fixture_log"))
    list_eq(pair.functions, { addr(truth, "ship_armor_a"), addr(truth, "ship_armor_b") })
    list_eq(pair.matches, { addr(truth, "ship_armor_a") + 4, addr(truth, "ship_armor_b") + 4 })
    eq(pair.address, addr(truth, "ship_armor_a") + 4)
    eq(pair.name, "#2")
    check(any.found and none.found)
    eq(any.address, nil)
    eq(#any.matches, 0)
end)

test("bundle: all or nothing", function()
    local called = {}
    local hooks = fn.bundle(target(), {
        before = function() called[#called + 1] = "before" end,
        after = function() called[#called + 1] = "after" end,
    })
    hooks:register(spec_of("ship_damage", { callback = function() called[#called + 1] = "ship_damage" end }))
    local legacy = hooks:register(spec_of("legacy_checksum", { callback = function() called[#called + 1] = "legacy" end }))
    local optional = hooks:register({
        name = "optional",
        signatures = { fn.signature.string("not in the fixture"), fn.signature.string("fixture: warning") },
        required = false,
    })
    local report = hooks:run()
    eq(report.ok, false)
    eq(#called, 0, "no callback, no before() or after()")
    list_eq(report.failed, { legacy })
    list_eq(report.skipped, { optional })
    eq(legacy.found, false)
    check(legacy.error:find("alternative 1: 0 functions, expected 1", 1, true), legacy.error)
    eq(optional.error, "alternative 1: 0 functions, expected 1; alternative 2: 2 functions, expected 1")
    check(report.error:find("^1 required entry not found: legacy_checksum %(alternative 1: 0 functions"), report.error)

    -- only optional entries missing: the run succeeds
    called = {}
    hooks = fn.bundle(target())
    hooks:register(spec_of("ship_damage", { callback = function() called[#called + 1] = "ship_damage" end }))
    hooks:register(spec_of("legacy_checksum", { required = false, callback = function() called[#called + 1] = "legacy" end }))
    report = hooks:run()
    check(report.ok, report.error)
    list_eq(called, { "ship_damage" })
    eq(#report.skipped, 1)
end)

test("bundle: symbol relations resolve in rounds", function()
    local hooks = fn.bundle(target())
    -- registered in the opposite order of what they need
    local thunk = hooks:register({ name = "ship_damage_thunk", signature = fn.signature.thunk_to("ship_damage") })
    local damage = hooks:register({ name = "ship_damage", signatures = ref_sigs("ship_damage", "^s_caller$") })
    local hull = hooks:register(spec_of("ship_hull"))
    local report = hooks:run()
    check(report.ok, report.error)
    eq(report.rounds, 3)
    eq(hull.address, addr(truth, "ship_hull"))
    eq(damage.address, addr(truth, "ship_damage"))
    eq(thunk.address, addr(truth, "ship_damage_thunk"))

    -- without the name the chain breaks
    hooks = fn.bundle(target())
    hooks:register({ name = "ship_damage_thunk", signature = fn.signature.thunk_to("ship_damage") })
    hooks:register({ signatures = ref_sigs("ship_damage", "^s_caller$") })
    hooks:register(spec_of("ship_hull"))
    report = hooks:run()
    eq(report.ok, false)
    eq(#report.failed, 1)
    eq(report.failed[1].name, "ship_damage_thunk")
end)

test("bundle: entries in several images", function()
    local hooks = fn.bundle()
    local old = hooks:register(spec_of("legacy_checksum", { image = ref }))
    local new = hooks:register(spec_of("ship_damage", { image = target() }))
    local report = hooks:run()
    check(report.ok, report.error)
    eq(report.images, 2)
    eq(old.address, addr(ref, "legacy_checksum"))
    eq(new.address, addr(truth, "ship_damage"))
end)

test("bundle: callback errors", function()
    local called = {}
    local hooks = fn.bundle(target(), { after = function() called[#called + 1] = "after" end })
    hooks:register(spec_of("ship_hull", { callback = function() called[#called + 1] = "hull" end }))
    hooks:register(spec_of("ship_damage", { callback = function() error("boom") end }))
    hooks:register(spec_of("mix_hash", { callback = function() called[#called + 1] = "mix" end }))
    raises(function() hooks:run() end, "callback of ship_damage failed")
    list_eq(called, { "hull", "after" })

    hooks = fn.bundle(target(), { before = function() error("not ready") end })
    hooks:register(spec_of("ship_hull"))
    raises(function() hooks:run() end, "not ready")
end)

test("bundle: misuse", function()
    raises(function() fn.bundle(5) end, "fnmatch.bundle: source must be an image, got number")
    raises(function() fn.bundle("x", {}) end, "source must be an image, got string")
    raises(function() fn.bundle(tgt, 5) end, "options must be a table")
    local hooks = fn.bundle(tgt)
    raises(function() hooks:register(5) end, "register() expects a table")
    raises(function() hooks:register({ name = "x" }) end, "x: no signature")
    raises(function() hooks:register({ name = "x", signatures = {} }) end, "x: no signature")
    raises(function() hooks:register({ name = "x", signature = "pic:1", signatures = { "pic:1" } }) end, "give either signature or signatures")
    raises(function() hooks:register({ name = "x", signatures = { "pic:1", "pic:xyz" } }) end, "x: signature #2: bad signature hash 'xyz'")
    raises(function() hooks:register({ name = "x", signatures = { { "pic:1", "nope:1" } } }) end, "x: signature #1.2: unknown signature kind 'nope'")
    raises(function() hooks:register({ name = "x", signatures = { 5 } }) end, "x: signature #1: string expected, got number")
    raises(function() hooks:register({ name = "x", signatures = { {} } }) end, "x: signature #1 is an empty list")
    raises(function() hooks:register({ name = "", signature = "pic:1" }) end, "name must be a non-empty string")
    raises(function() hooks:register({ name = 5, signature = "pic:1" }) end, "name must be a non-empty string")
    raises(function() hooks:register({ signature = "pic:1", count = -1 }) end, "count must be")
    raises(function() hooks:register({ signature = "pic:1", count = 1.5 }) end, "count must be")
    raises(function() hooks:register({ signature = "pic:1", offset = "4" }) end, "offset must be a number")
    raises(function() hooks:register({ signature = "pic:1", callback = 5 }) end, "callback must be a function")
    raises(function() hooks:register({ signature = "pic:1", image = 5 }) end, "image must be an image")
    raises(function() hooks:register({ signature = "pic:1", module = 5 }) end, "module must be a string")
    raises(function() fn.bundle():register({ signature = "pic:1" }) end, "no image")
    local err = raises(function() hooks:register({ name = "x", signatures = { "pic:xyz" } }) end)
    check(err:find("test_fnmatch.lua", 1, true), "errors point at the caller: " .. err)
    hooks:run()
    raises(function() hooks:run() end, "run() can only be called once")
    raises(function() hooks:register({ signature = "pic:1" }) end, "register() after run()")
end)

--------------------------------------------------
-- modules of this process
--

test("modules", function()
    local image, message = fn.module("no_such_module.dll")
    eq(image, nil)
    eq(message, "module not loaded: no_such_module.dll")

    local hooks = fn.bundle()
    local entry = hooks:register({ name = "x", module = "no_such_module.dll", signature = "pic:1" })
    local report = hooks:run()
    eq(report.ok, false)
    eq(entry.error, "module not loaded: no_such_module.dll")

    if fn.platform == "linux" then
        -- a module is found in /proc/self/maps; ELF files are not PE files
        local name
        for line in io.lines("/proc/self/maps") do
            name = name or line:match("/([^/]+%.so[%.%d]*)$")
        end
        if name then
            image, message = fn.module(name)
            eq(image, nil)
            check(message:find("not an MZ file", 1, true), message)
        end
    end
end)

if fn.platform == "windows" and has_ffi then
    ffi.cdef [[
        void *LoadLibraryA(const char *name);
        void *GetProcAddress(void *module, const char *name);
        int FreeLibrary(void *module);
    ]]

    test("a loaded module (Windows)", function()
        local module = ffi.C.LoadLibraryA((V2:gsub("/", "\\")))
        check(module ~= nil, "LoadLibrary " .. V2)
        local base = tonumber(ffi.cast("uintptr_t", module))
        local function proc(name)
            return tonumber(ffi.cast("uintptr_t", ffi.C.GetProcAddress(module, name)))
        end

        local image = assert(fn.module("fixture_v2.dll"))
        eq(image:base(), base)
        eq(image:md5(), tgt:md5())
        list_eq(image:find(fn.signature.export("fixture_update")), { proc("fixture_update") })
        list_eq(image:find(ref_sigs("mix_hash", "^pic$")), { base + addr(truth, "mix_hash") - truth:base() })
        image:close()

        -- a bundle analyses the module when it runs, and closes it afterwards
        local seen
        local hooks = fn.bundle({ threads = 2 })
        local tick = hooks:register({
            module = "FIXTURE_V2.DLL", -- module names ignore case
            name = "fixture_tick",
            signature = fn.signature.export("fixture_tick"),
            callback = function(address, entry) seen = { address, tostring(entry.image) } end,
        })
        local update = hooks:register(spec_of("fixture_update", { module = "fixture_v2.dll" }))
        local report = hooks:run()
        check(report.ok, report.error)
        eq(report.images, 1, "one analysis per module")
        eq(tick.address, proc("fixture_tick"))
        eq(update.address, proc("fixture_update"))
        eq(seen[1], proc("fixture_tick"))
        check(seen[2]:find("fixture_v2.dll", 1, true), "open during the callbacks")
        eq(tostring(tick.image), "fnmatch.image (closed)")

        hooks = fn.bundle({ keep_images = true })
        tick = hooks:register({ module = "fixture_v2.dll", signature = fn.signature.export("fixture_tick") })
        check(hooks:run().ok)
        list_eq(tick.image:find(fn.signature.export("fixture_log")), { proc("fixture_log") })

        ffi.C.FreeLibrary(module)
    end)
end

--------------------------------------------------
-- memory
--

test("garbage collection", function()
    for _ = 1, 20 do
        local image = target({ threads = 2 })
        image:find(fn.signature.export("fixture_tick"))
        local sf = fn.sig_file(SIG1)
        sf:signatures("ship_damage")
        local hooks = fn.bundle(image)
        hooks:register(spec_of("ship_hull"))
        hooks:run()
    end
    local closed = target()
    closed:close()
    closed = nil
    collectgarbage("collect")
    collectgarbage("collect")
end)

--------------------------------------------------
-- run
--

local failures = 0
for _, t in ipairs(tests) do
    local ok, err = xpcall(t.fn, debug.traceback)
    if ok then
        print("ok      " .. t.name)
    else
        failures = failures + 1
        print("FAILED  " .. t.name .. "\n" .. tostring(err))
    end
end

print(string.format("\n%d tests, %d failed (%s, %s%s)", #tests, failures,
    jit and jit.version or _VERSION, fn.platform, has_ffi and ", ffi" or ""))
if failures > 0 then
    error(failures .. " test(s) failed", 0)
end
