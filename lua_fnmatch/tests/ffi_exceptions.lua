-- ffi_exceptions.lua <case> <fixtures dir> [module dir]: one experiment on a C++ exception thrown
-- by a function called through the LuaJIT FFI (the fixture's ffx_throw_if(42) throws FfxError),
-- run on Windows x64. Each case runs in a process of its own (some end the process); the driver
-- is ffi_exceptions.ps1 and docs are in the README ("C++ exceptions").
--
-- Prints "CAUGHT <message>" when a Lua pcall caught the exception, "RETURNED" when the code went
-- on without one, and nothing more when the process died.

local case, fixtures, module_dir = ...
if module_dir and module_dir ~= "" then
    package.cpath = module_dir .. "/?.dll;" .. package.cpath
end
local fnmatch = require("fnmatch")
local ffi = require("ffi")
local dir = fixtures .. "/ffi/"
local b = assert(fnmatch.ffi.load(dir .. "ffi_fixture.ffi.lua"))
pcall(ffi.cdef, "void *LoadLibraryA(const char *name);")
local base = tonumber(ffi.cast("uintptr_t", ffi.C.LoadLibraryA(dir .. "ffi_fixture.dll")))
local d = assert(b:func("ffx_throw_if"))
local throw = b:fn("ffx_throw_if", base + d.rva)
io.stdout:setvbuf("no")

local function hot(f, n)
    -- n calls, the last one throws: the loop is compiled long before
    local s = 0
    for i = 1, n do
        s = s + f(i == n and 42 or 1)
    end
    return s
end

local cases = {
    -- the FFI call is interpreted: LuaJIT's handler turns the exception into a Lua error
    interpreted = function()
        jit.off()
        return pcall(throw, 42)
    end,
    -- the FFI call is inside a compiled trace
    compiled = function()
        return pcall(hot, throw, 100000)
    end,
    -- compiled loop, but the call goes through fnmatch.ffi.protect (never compiled)
    protected = function()
        return pcall(hot, fnmatch.ffi.protect(throw), 100000)
    end,
    -- compiled loop with the loop's function excluded from compilation
    jit_off_function = function()
        local h = function(...) return hot(...) end
        jit.off(hot)
        return pcall(h, throw, 100000)
    end,
    -- no pcall: the exception reaches the host (the luajit.exe's own lua_pcall, or a C++ host)
    unprotected = function()
        throw(42)
        return true
    end,
    -- no pcall, compiled
    unprotected_compiled = function()
        hot(throw, 100000)
        return true
    end,
}

local f = cases[case]
if f == nil then
    error("unknown case " .. tostring(case))
end
local ok, err = f()
if ok == false then
    print("CAUGHT " .. tostring(err))
else
    print("RETURNED")
end
-- the state after the exception: still usable?
local again, e2 = pcall(throw, 1)
print("AFTER " .. tostring(again) .. " " .. tostring(e2))
