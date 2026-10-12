// lua_fnmatch.h : Lua bindings for stellar-fnmatch function signatures.
//
// Built as a Lua module, `require("fnmatch")` finds `luaopen_fnmatch` on its own. When the static
// library is linked into a host instead (define LUA_FNMATCH_STATIC), register it with e.g.
// `luaL_requiref(L, "fnmatch", luaopen_fnmatch, 0)` or by storing `luaopen_fnmatch` in
// `package.preload["fnmatch"]`.

#pragma once

#if defined(__cplusplus)
    #include <lua.hpp>
#else
    #include <lua.h>
#endif

#if defined(LUA_FNMATCH_STATIC)
    #define LUA_FNMATCH_API
#elif defined(_WIN32)
    #if defined(LUA_FNMATCH_BUILDING)
        #define LUA_FNMATCH_API __declspec(dllexport)
    #else
        #define LUA_FNMATCH_API __declspec(dllimport)
    #endif
#else
    #define LUA_FNMATCH_API __attribute__((visibility("default")))
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Pushes the module table and returns 1.
LUA_FNMATCH_API int luaopen_fnmatch(lua_State *L);

#if defined(__cplusplus)
}
#endif
