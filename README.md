# lua_fnmatch

Lua bindings for the function signatures of
[stellar-fnmatch](https://github.com/MattMills/stellar-fnmatch): find functions of an executable
from Lua by any of its signature kinds, in the running process or in files. It is the companion of
[lua_sigmatch](https://github.com/MattMills/lua_sigmatch): where sigmatch finds byte patterns,
fnmatch finds functions by what identifies them across builds (code shape, strings, constants,
imports, call graph, layout, vtables, ...).

- An image is an executable analysed exactly as `stellar-fnmatch extract` + `sigs` do: every
  function and every signature of every function, of all 41 kinds, indexed. A lookup returns the
  functions that carry a signature; when that is one function, it is found.
- Signatures come from the `.sig` files of stellar-fnmatch (one per build, e.g. the GOG build with
  a PDB of the same version), from an image of a build with its PDB, or from known facts (a
  string, an export name, a constant).
- `fnmatch.bundle` works like `sigmatch.bundle`: hooking code registers signatures with callbacks,
  one `run()` analyses each module once, resolves everything, and only if all of it was found runs
  the callbacks together.
- It works with LuaJIT and Lua 5.1 to 5.4, on Windows and Linux, as a loadable module
  (`fnmatch.dll` / `fnmatch.so`) or as a static library linked into a host that embeds Lua.

```lua
local fnmatch = require("fnmatch")

-- signatures of the functions to hook, taken from the GOG build of the same version
local reference = assert(fnmatch.sig_file("sigs/gog-4.5.2.sig"))

local hooks = fnmatch.bundle()
hooks:register({
    name = "CShip::CalcRegenAmount",
    module = "stellaris.exe",
    signatures = reference:signatures("CShip::CalcRegenAmount"), -- alternatives, in order
    callback = function(address, entry) install_hook(address, calc_regen_amount) end,
})

local report = hooks:run()
if not report.ok then
    print(report.error) -- e.g. 1 required entry not found: CShip::CalcRegenAmount (alternative 1: 0 functions, expected 1; ...)
end
```

## Building

```sh
git clone --recursive https://github.com/MattMills/lua_fnmatch.git   # or: git submodule update --init
cmake --preset linux-debug            # Windows: x64-debug / x64-release from a VS developer prompt
cmake --build out/build/linux-debug
ctest --test-dir out/build/linux-debug --output-on-failure
```

Two submodules: `lua_fnmatch/lib/luajit` ([MattMills/LuaJIT](https://github.com/MattMills/LuaJIT),
built like in lua_sigmatch: `make` on Linux and MinGW, `msvcbuild.bat` with MSVC) and
`lua_fnmatch/lib/stellar-fnmatch`. The engine (`lua_fnmatch/engine`, Rust) is a static library
over stellar-fnmatch that CMake builds with cargo, always optimized. It needs a Rust toolchain
(https://rustup.rs) and a C++17 compiler.

| Target               | Output                       | Use                                          |
|----------------------|------------------------------|----------------------------------------------|
| `lua_fnmatch`        | `fnmatch.dll` / `fnmatch.so` | `require("fnmatch")`                         |
| `lua_fnmatch_static` | static library               | link into a host, register `luaopen_fnmatch` |

On Windows the module links against `lua51.dll`, and the host must load that same DLL. On Linux the
module takes the Lua symbols from the host process and exports only `luaopen_fnmatch`.

| CMake option                   | Default | Meaning                                                    |
|--------------------------------|---------|------------------------------------------------------------|
| `LUA_FNMATCH_LUA_INCLUDE_DIR`  | empty   | Lua headers to build against instead of the submodule      |
| `LUA_FNMATCH_LUA_LIBRARY`      | empty   | Lua library: the module links it on Windows, the embedding test everywhere |
| `LUA_FNMATCH_LUA_INTERPRETER`  | empty   | interpreter for the module test (the submodule's `luajit` by default) |
| `LUA_FNMATCH_BUILD_MODULE`     | `ON`    | build `fnmatch.dll` / `fnmatch.so`                         |
| `LUA_FNMATCH_BUILD_STATIC`     | `OFF`   | build `lua_fnmatch_static` by default (it builds on demand anyway) |
| `LUA_FNMATCH_CARGO`            | empty   | cargo, if it is not on the PATH or in `~/.cargo/bin`       |
| `LUA_FNMATCH_RUST_TARGET`      | empty   | Rust target of the engine (`x86_64-pc-windows-gnu` with MinGW) |
| `LUA_FNMATCH_RUST_STATIC_CRT`  | `OFF`   | MSVC: build the engine with the static C runtime, for hosts built with `/MT` |
| `LUA_FNMATCH_BUILD_TESTS`      | `ON` when top level | register the tests with CTest                  |

### Embedding in a host (e.g. stellar-injected)

As with lua_sigmatch, a host that links LuaJIT statically links the static library and registers
the bindings itself:

```cmake
set(LUA_FNMATCH_LUA_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit/src" CACHE PATH "")
set(LUA_FNMATCH_BUILD_MODULE OFF CACHE BOOL "")
# set(LUA_FNMATCH_RUST_STATIC_CRT ON CACHE BOOL "")   # if the host uses the static CRT (/MT)
add_subdirectory(lib/lua_fnmatch)
target_link_libraries(stellar-injected PRIVATE lua_fnmatch::static)   # plus your LuaJIT
```

```cpp
#include <lua_fnmatch.h>

// package.preload["fnmatch"] = luaopen_fnmatch, so scripts can require("fnmatch")
lua_getglobal(L, "package");
lua_getfield(L, -1, "preload");
lua_pushcfunction(L, luaopen_fnmatch);
lua_setfield(L, -2, "fnmatch");
lua_pop(L, 2);
```

The static library only exposes `lua_fnmatch.h` and the Lua headers; it brings the engine archive
and the system libraries the Rust standard library needs. Its symbols are prefixed `fnme_`, but a
binary should not link two Rust static libraries (their standard libraries would clash).

## Lua API

**Errors.** Bad arguments raise Lua errors. An executable, PDB or `.sig` file that cannot be read
returns `nil` and a message.

**Addresses** are integers on Lua 5.3+ and numbers on Lua 5.1 / LuaJIT (exact up to 2^53). Address
arguments also accept light userdata.

### Module

| Field | |
|---|---|
| `_VERSION`, `fnmatch_version` | `"lua_fnmatch 0.1.0"`, the version of stellar-fnmatch |
| `platform` | `"windows"` or `"linux"` |
| `kinds` | the 41 signature kind names, in the order of their numbers |
| `hardware_concurrency` | the default number of analysis threads |

### Signatures

A signature is a 64-bit value: a kind (6 bits) and a hash (58 bits). In Lua it is a string
`"<kind>:<hash>"`, the hash in 15 hex digits, e.g. `"pic:2a9f0c1d3e4b5a6"`, as stellar-fnmatch
writes it (`sigs::format`). The 16 hex digits of the raw value are accepted too.

```lua
fnmatch.signature("pic:2a")             -- the canonical text, "pic:00000000000002a"; raises on malformed input
fnmatch.signature.parse(text)           -- the canonical text, or nil and a message
fnmatch.signature.kind(sig)             -- "pic"
```

Kinds (see stellar-fnmatch's [SCHEMA.md](https://github.com/MattMills/stellar-fnmatch/blob/main/SCHEMA.md)):

| Kinds | |
|---|---|
| `exact`, `pic`, `mnem`, `bagcfg`, `unwind`, `block` | code shape: raw bytes, position-independent code, mnemonics, mnemonic histogram + CFG, unwind info, basic blocks |
| `str`, `strset`, `istr`, `const`, `imm`, `imports`, `export` | data: each string, the set of strings, strings behind data objects, read-only constants, immediates, imported functions, export name |
| `callee_shapes`, `caller_shapes`, `wl1`, `layout3` | structure: the shapes of callees / callers, a one-step Weisfeiler-Lehman colour, the neighbours in address order |
| `a_<relation>` | relations to a neighbour identified by one of its own unique signatures |
| `s_<relation>` | relations to a neighbour identified by its name |

Relations: `callee_ord`, `caller`, `callset`, `callee_pair`, `thunk`, `vtslot`, `layout_prev`,
`layout_next`, `table_prev`, `table_next`, `global`, `fnptr`.

Some signatures can be written from facts about a function:

| Function | The function... |
|---|---|
| `fnmatch.signature.string(text)` | references this string literal |
| `fnmatch.signature.wide_string(text)` | references this UTF-16 string literal |
| `fnmatch.signature.indirect_string(text)` | references a data object that points to this string |
| `fnmatch.signature.export(name)` | is exported under this name |
| `fnmatch.signature.immediate(value)` | uses this immediate (number, or up to 16 hex digits; negative values are two's complement). `add` / `sub` immediates below 0x10000 are not recorded |
| `fnmatch.signature.constant(bytes)` | loads these 1 to 32 bytes of read-only data, e.g. the 4 bytes of a float |
| `fnmatch.signature.thunk_to(name)` | is a one-instruction thunk to the function with this name |

### Images

```lua
fnmatch.module(name [, options])      -- a module loaded in this process, analysed from its file
fnmatch.file(path [, options])        -- an executable file (x64 PE)
fnmatch.image(contents [, options])   -- the contents of an executable file, as a string
```

| Option | |
|---|---|
| `pdb` | the PDB of the executable: functions get their names |
| `base` | (`file`, `image`) the address of the image; default: the PE image base. For `module`, the load address |
| `cache` | a directory where the analysis of each executable is kept, by md5 (`<md5>.fnx`), so the next start skips it |
| `threads` | analysis threads, default: one per core |
| `name` | (`image`) the name in messages |

A module is analysed from its file on disk, not from memory: the signatures are the same as those
stellar-fnmatch computed for the build, whatever was patched or relocated in memory since.
`fnmatch.module` finds the module with `GetModuleHandle` on Windows and in `/proc/self/maps` on
Linux, and returns addresses where it is loaded.

| Method | |
|---|---|
| `image:find(sig)` | addresses of the functions that carry the signature (or all signatures of a list), in address order |
| `image:signatures(address [, all])` | the signatures of the function containing `address`: those no other function has, or all of them |
| `image:function_at(address)`, `image[i]` | a function description, or nil |
| `image:functions_named(name)` | the functions with this name (from the PDB or `set_name`) |
| `image:set_name(address, name)` | names a function (nil removes the name), for the symbol relations around it |
| `image:base()`, `image:path()`, `image:md5()`, `image:has_pdb()`, `#image` | |
| `image:signature_count()` | number of (signature, function) pairs, symbol relations not included |
| `image:close()` | frees the analysis now |

A function description has `index`, `address`, `end_address` (end of its main code range), `rva`,
`size` (bytes of decoded instructions), `instructions`, `flags` (stellar-fnmatch `model::ff`),
`names`, and for C++ EH funclets `funclet_of` (the address of the owning function) and
`funclet_kind` (`"unwind"` or `"catch"`).

**Symbol relations** (`s_*`) identify a neighbour by the hash of its name: they resolve in an
image with a PDB, and in a stripped image once its functions have names (`set_name`, or the entries
of a bundle). Names are PDB procedure names; lambda and anonymous-namespace hashes are normalized
as in stellar-fnmatch.

**Time and memory.** Analysing a Stellaris 4.5 executable (130,000 functions, 7 million
signatures) takes about 2.5 s with 8 threads and peaks at about 700 MB; the image then keeps about
190 MB, and a loaded `.sig` file about 130 MB. A lookup takes microseconds. The Lua collector does
not see these sizes, so close images and sig files you are done with (a bundle closes the images it
opened).

### Sig files

```lua
local reference = assert(fnmatch.sig_file("sigs/gog-4.5.2.sig"))
reference:signatures("CShip::CalcRegenAmount")   -- by name (exactly one function) or by RVA
```

A `.sig` file (`stellar-fnmatch sigs`) holds, per build, the signatures that are unique inside that
build, and the PDB names when the build has them. `sig_file:signatures(name | rva)`,
`sig_file:find(sig)` (the function carrying it), `sig_file:functions_named(name)`,
`sig_file:function_at(rva)`, `sig_file[i]`, `#sig_file`, `id()`, `platform()`, `version()`,
`build_string()`, `md5()`, `signature_count()`, `close()`. Descriptions are like those of images,
with `rva` and `end_rva` instead of addresses.

An image's `signatures(address)` and the `.sig` file of the same build give the same signatures.

### Instructions

```lua
local i = fnmatch.decode(bytes [, address [, position]])
-- { length = 5, flow = "next", rip_relative = false, text = "mov [rsp+8],rbx" }
```

The x64 instruction at `position` (1-based, default 1) of a string of bytes whose first byte is at
`address` (default 0), decoded with iced-x86 (the decoder stellar-fnmatch uses), or nil when the
bytes there are not a whole valid instruction. `flow` is `next`, `branch`, `indirect_branch`,
`conditional_branch`, `return`, `call`, `indirect_call`, `interrupt`, `xbegin` or `exception`;
`target` is the target of a near branch or call, or the address a RIP-relative operand refers to;
`text` is Intel syntax. C hosts get the same from `fnme_decode` (`fnmatch_engine.h`), e.g. to find
whole instructions to move out of the way of a hook.

### Bundles: register hooks, resolve them all, install them together

```lua
local hooks = fnmatch.bundle([image] [, options])
local entry = hooks:register(spec)
local report = hooks:run()
```

`fnmatch.bundle(source, options)` takes an image (the default of every entry) or nothing (entries
then name a `module`). Options:

- `cache`, `threads`: how `run()` analyses modules.
- `keep_images`: keep the images `run()` opened. By default they are closed when it returns.
- `before(report)`, `after(report)`: called around the callbacks.

`bundle:register(spec)`:

| Field | Meaning |
|---|---|
| `signature` or `signatures` | one signature, or alternatives tried in order: the first carried by the expected number of functions wins. An alternative can be a list of signatures that must all be on the function |
| `name` | for reports; once found, the entry's functions get this name, which the symbol relations of other entries refer to |
| `module` / `image` | where to look (default: the bundle's image) |
| `count` | expected number of functions, default `1`; `false` accepts any number |
| `offset` | added to every function address, default `0` |
| `required` | default `true`; a missing optional entry is skipped instead of failing the run |
| `priority` | callbacks run by ascending priority (default `0`), then in registration order |
| `callback(address, entry, fn)` | `address` is the first function plus `offset`; `fn` the typed function, with bindings |
| `ffi` | `fnmatch.ffi` bindings for this entry (default: the bundle option `ffi`), or `false` |
| `declaration` | with bindings: which declaration of `name` (an index, the RVA in the bindings' build, or the declaration); default: the only one |
| `protect` | with bindings: passed to `bindings:fn` |

After `run()`, an entry has `found`, `address`, `matches` (offset applied), `functions` (the
function addresses), `signature` and `alternative` (the one that matched), `image`, and `error` (why
it wasn't found); with bindings also `fn` (the typed function at `address`) and `declaration` (its
metadata). An entry with bindings needs a `name` that the bindings declare; `register` checks it.

`bundle:run()` can be called once:

1. **One analysis per image.** All entries of a module share one analysis.
2. **Rounds of lookups.** Each entry takes its first alternative carried by `count` functions. A
   found entry names its functions, so `s_*` signatures of other entries that refer to those names
   can resolve in the next round. Rounds repeat until one finds nothing new.
3. **All or nothing.** If a required entry is missing, no callback runs, and the report says what
   is missing and why. Otherwise `before()` runs, then every callback back to back, then
   `after()`. If a callback raises an error, the remaining callbacks are skipped, `after()` still
   runs, and the error propagates.

The report has `ok`, `entries`, `failed` (required entries that weren't found), `skipped`
(optional ones), `images` (how many images the entries used), `rounds` and `error`.

### Typed functions and classes: fnmatch.ffi

`stellar-fnmatch cdef` writes, from a build's PDB, a Lua module of LuaJIT FFI declarations: classes
with every data member at its PDB offset, and functions declared for the MSVC x64 calling
convention, with their vtable slots and whether they may throw (stellar-fnmatch's
[docs/ffi.md](https://github.com/MattMills/stellar-fnmatch/blob/main/docs/ffi.md) has the rules and
how they were checked). `fnmatch.ffi` (pure Lua, `ffi.lua`) uses it:

```lua
local b = assert(fnmatch.ffi.load("gog-4.5.2.ffi.lua"))   -- or the module's table

local hooks = fnmatch.bundle(fnmatch.module("stellaris.exe"), { ffi = b })
hooks:register({
    name = "CTextLexer::GetTok",
    signatures = reference:signatures("CTextLexer::GetTok"),
    callback = function(address, entry, get_tok)    -- get_tok: int32_t (*)(CTextLexer *)
        lexer_get_tok = get_tok
    end,
})

local obj = ffi.cast(b:ptr("CNamedColor"), p)   -- p: an object the game made
print(obj._Index)                                -- a member of a base (TGameDatabaseObject)
local persistent = b:cast(obj, "CPersistent")    -- the base subobject at +0x40
local copy = b:type("CNamedColor")()             -- a ctype, declared with what it needs
local n = b:vcall(lexer, "CTextLexer::GetTok")   -- a virtual call through the object's vtable
```

| Function | |
|---|---|
| `fnmatch.ffi.load(path or table [, options])` | bindings for a generated module, or nil and a message; `options.protect` is the default of `fn` |
| `fnmatch.ffi.available` | false without the LuaJIT FFI: then every function raises "the LuaJIT FFI is not available" |
| `fnmatch.ffi.protect(f)` | a Lua function that calls `f` and is never compiled |
| `b:type(name)`, `b:ptr(name)` | the ctype of a class, struct, union or enum (C or C++ name), or of a pointer to it (opaque is enough) |
| `b:declare(name [, complete])` | declares it (and everything it needs), returns its C name |
| `b:info(name)`, `b:field(name, member)`, `b:enum(name)` | metadata: size, fields (offset, C++ type, bits), bases, vfptrs; enum values both ways |
| `b:cast(object, base [, from])` | a pointer to the base class subobject of a pointer to a class of the module |
| `b:getbits(object, type, field)`, `b:setbits(...)` | bitfields LuaJIT cannot declare (in a 64-bit unit, across bit 32) |
| `b:functions(name)`, `b:func(name [, which])` | the declarations of a function (overloads, folded copies), or one: `which` is an index, the RVA in the module's build, or the declaration |
| `b:fntype(name [, which])` | the ctype of its function pointer, with its types declared |
| `b:fn(name, address [, which [, options]])` | the typed function at `address`, and its declaration; `options.protect = true` wraps it (`"throws"`: only functions that may throw) |
| `b:vfn(object, name [, which])` | the virtual method from the object's vtable, and the `this` to pass (the subobject that holds the vfptr); for a destructor the deleting destructor, `fn(this, 1)` frees the object |
| `b:vcall(object, name, ...)` | calls it |

- **Declared on demand.** A Lua state has room for 65,536 ctypes; all of 4.5.2's types make
  563,268. `type`, `fn` and the bundle declare a type with its closure the first time it is used
  (types used only through pointers as `struct X;`), in one `ffi.cdef`.
- **One module per name.** Types are recorded per Lua state with the module (PDB) that declared
  them; another module that wants the same C name fails with a message (generate one of them with
  `--prefix`).
- **What the declarations change** from the C++ signature is in each declaration's `rewrites`: a
  class result through a hidden pointer (after `this` for methods, first otherwise: pass a
  buffer, the function returns it), a by-value class as a pointer to a copy that the callee destroys,
  `this` as the base subobject for an override through a secondary base, the deleting destructor in
  a virtual destructor's slot.
- **Floats, varargs.** `float` and `double` parameters work as declared. Variadic functions take
  integers as cdata (`ffi.new("int32_t", 3)`): a Lua number goes as a `double`.

#### C++ exceptions

`throws` in a declaration says whether the function may throw a C++ exception (`"yes"`,
`"maybe"`: only through virtual or indirect calls, `"no"`), and `via` what kind. The LuaJIT
documentation says C++ exception interoperability "does not extend to C functions called via the
FFI, if the call is compiled". Measured on Windows x64 with this repository's LuaJIT (2.1 at
6f54a53, which stellarstellaris-win builds too) and an MSVC-built DLL (`tests/ffi_exceptions.ps1`,
each case in its own process):

| the FFI call that throws | standalone `luajit.exe` | C++ host, `/EHsc` | C++ host, `/EHs` |
|---|---|---|---|
| interpreted, under `pcall` | caught: "C++ exception" | caught by the `pcall` | caught by the `pcall` |
| compiled in a trace (`CALLXS` in the IR), under `pcall` | caught | caught | caught |
| through `fnmatch.ffi.protect`, or a function under `jit.off`, under `pcall` | caught | caught | caught |
| no `pcall` (interpreted or compiled) | `lua_pcall` of `luajit.exe` reports "C++ exception" | the process ends (0xC0000409) | the host's `catch (FfxError&)` gets the original exception |

After each catch the Lua state works. So:
- a `pcall` around a call that may throw turns the exception into the Lua error "C++ exception"
  (the C++ exception object is destroyed), whether or not the call is compiled: Windows x64 builds
  of this LuaJIT unwind through traces (`LJ_UNWIND_JIT`);
- without one the exception goes to the C++ code that called into Lua; that code must be compiled
  with `/EHs` or `/EHa`: with `/EHsc` the compiler assumes `lua_call` cannot throw and drops the
  `catch`;
- `protect` is for LuaJIT builds without unwinding through traces.

## Choosing signatures

A signature from a `.sig` file is unique in its own build. In another build it can be gone (the
function changed), shared, or, rarely, carried by a single different function: then the bundle
takes the wrong function. Measured on Stellaris (2000 random functions, not compiler-generated
initializers), using every unique signature of the function as alternatives in kind order:

| Target | Reference | Found, right | Wrong | Not found |
|---|---|---|---|---|
| Steam 4.5.2 | GOG 4.5.2 `.sig` (same version) | 99.05% | 0 | 0.95% |
| GOG 4.5.2 (without its PDB) | GOG 4.5.1 `.sig` (previous patch), all kinds | 97.55% | 0.90% | 1.55% |
| GOG 4.5.2 (without its PDB) | GOG 4.5.1 `.sig`, without `imm`, `a_vtslot`, `a_table_*` | 97.65% | 0.10% | 2.25% |

(Steam: agreement with the labels of `stellar-fnmatch match`. GOG 4.5.2: checked against its PDB.)

Signatures of one kind that resolved to one function of 4.5.2, from 4.5.1:

| Precision | Kinds |
|---|---|
| 100% | `mnem`, `bagcfg`, `unwind`, `str`, `strset`, `istr`, `const`, `imports`, `export`, `callee_shapes`, `caller_shapes`, `wl1`, `layout3`, `a_callee_ord`, `a_callset`, `a_global`, `a_fnptr` |
| 99 to 99.9% | `block`, `a_caller`, `a_layout_prev`, `a_layout_next` |
| about 98.7% | `exact`, `pic` (near-identical functions such as static initializers trade places) |
| 72 to 85% | `imm`, `a_vtslot`, `a_table_prev`, `a_table_next` (tables and vtables change between patches) |

So across versions, leave out `imm`, `a_vtslot` and `a_table_*`, or combine them with another
signature in a list (`{ sig1, sig2 }`). Within one version, all kinds are safe.

```lua
local unreliable = { imm = true, a_vtslot = true, a_table_prev = true, a_table_next = true }
local function alternatives(reference, name)
    local out = {}
    for _, sig in ipairs(reference:signatures(name)) do
        if not unreliable[fnmatch.signature.kind(sig)] then
            out[#out + 1] = sig
        end
    end
    return out
end
```

## Tests

`ctest` runs `lua_fnmatch/tests/test_fnmatch.lua` twice: with the module loaded by `require`, and
with the static library linked into a small host program (`lua_fnmatch/tests/embed_host.cpp`).
The fixtures in `lua_fnmatch/tests/fixtures` are two builds of a small x64 DLL with their PDBs and
the `.sig` file of the first (`build_fixtures.sh`: clang, lld-link and stellar-fnmatch): the second
build adds, changes and removes functions, and everything moves. The suite covers:

- the text form of signatures and the signatures from facts
- images of files and strings, options, the cache, errors
- every signature kind present, image signatures equal to the `.sig` file's
- the first build's signatures in the second: every one that resolves to one function resolves
  to the right one; changed and removed functions; lists of signatures; shared signatures
- symbol relations following the names given to functions
- `.sig` files
- bundles: priorities, alternatives, counts, offsets, all-or-nothing behaviour, symbol relations
  resolved over several rounds, several images, callback errors, misuse
- modules of the process: on Windows (with the LuaJIT FFI) the DLL is loaded and the addresses are
  checked against `GetProcAddress`; on Linux the lookup in `/proc/self/maps`

It passes on Linux with LuaJIT, Lua 5.1 and Lua 5.4 (GCC, also under ASan + UBSan), and on Windows
with MSVC 2022 (Release, Debug, and the static CRT).

`ctest` also runs `lua_fnmatch/tests/test_ffi.lua` both ways. Its fixture,
`lua_fnmatch/tests/fixtures/ffi`, is a DLL built with MSVC (`ffi_fixture.cpp`,
`build_ffi_fixture.cmd`), its PDB, and the declarations `stellar-fnmatch cdef` generated from them
(`ffi_fixture.ffi.lua`). The C++ code has the cases the declarations must get right: results of 8
and 24 bytes, POD and not, from functions, methods and static methods; classes by value with a copy
constructor, a defaulted copy constructor, a move constructor (user-provided and defaulted) or only
a destructor; floats and integers by position, past the fourth; varargs; bitfields in units of 1,
2, 4 and 8 bytes (one across bit 32); `#pragma pack`; an anonymous union with an anonymous struct; an
enum; two vfptrs and an override through the second; a throwing function. The test checks every
layout under the running LuaJIT, the rules each declaration records, the type registry, bundles
with typed functions, and on Windows calls everything (the results come from the C++ code) and
catches a C++ exception through an FFI call. Without the FFI (Lua 5.x) it checks the errors. 476
checks on Windows; it passes on Linux with LuaJIT, Lua 5.1.5 and 5.4.7, and on Windows with MSVC
2022. `ffi_exceptions.ps1` is the exception experiment above (not part of `ctest`: some cases end
the process).

## License

MIT (see `LICENSE.txt`). stellar-fnmatch and LuaJIT are MIT.
