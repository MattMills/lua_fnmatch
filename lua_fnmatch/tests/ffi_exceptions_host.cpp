// ffi_exceptions_host.cpp: runs ffi_exceptions.lua with lua_call (no protected call) inside a
// C++ try/catch, to see what reaches a C++ host when a C++ exception thrown by a function called
// through the LuaJIT FFI is not caught in Lua. Part of the experiment in ffi_exceptions.ps1.
//
//   ffi_exceptions_host <script> <case> <fixtures dir> <module dir>
//
// Build (VS x64 prompt, against the lua51.dll the fnmatch module uses):
//   cl /nologo /EHsc /O1 /I<luajit>/src ffi_exceptions_host.cpp /link <luajit>/src/lua51.lib

#include <cstdio>

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

// the fixture's exception type (ffi_fixture.cpp): the same name, so catch matches it
struct FfxError {
    int code;
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s script.lua [args...]\n", argv[0]);
        return 2;
    }
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    if (luaL_loadfile(L, argv[1]) != 0) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 2;
    }
    for (int i = 2; i < argc; ++i) {
        lua_pushstring(L, argv[i]);
    }
    try {
        lua_call(L, argc - 2, 0);
        std::printf("HOST returned\n");
    } catch (const FfxError &e) {
        std::printf("HOST caught FfxError %d\n", e.code);
    } catch (...) {
        std::printf("HOST caught another exception\n");
    }
    // is the Lua state still usable?
    int status = luaL_dostring(L, "return 1 + 1");
    std::printf("HOST state after: %s\n", status == 0 ? "usable" : lua_tostring(L, -1));
    std::fflush(stdout);
    lua_close(L);
    return 0;
}
