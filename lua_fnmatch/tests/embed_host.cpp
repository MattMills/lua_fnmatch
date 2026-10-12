// embed_host.cpp : runs a Lua script with the static fnmatch bindings preloaded, the way a host
// application that embeds Lua links them in.
//
// Usage: lua_fnmatch_embed_host script.lua [args...]

#include "lua_fnmatch.h"

#include <cstdio>

namespace {

int traceback(lua_State *L)
{
    const char *message = lua_tostring(L, 1);
    lua_getglobal(L, "debug");
    lua_getfield(L, -1, "traceback");
    lua_pushstring(L, message != nullptr ? message : "(error object is not a string)");
    lua_pushinteger(L, 2);
    lua_call(L, 2, 1);
    return 1;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s script.lua [args...]\n", argv[0]);
        return 2;
    }

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    // package.preload["fnmatch"] = luaopen_fnmatch
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_fnmatch);
    lua_setfield(L, -2, "fnmatch");
    lua_pop(L, 2);

    lua_pushcfunction(L, traceback);
    int status = luaL_loadfile(L, argv[1]);
    if (status == 0) {
        for (int i = 2; i < argc; ++i) {
            lua_pushstring(L, argv[i]);
        }
        status = lua_pcall(L, argc - 2, 0, 1);
    }
    if (status != 0) {
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
    }

    lua_close(L); // also runs every __gc
    return status == 0 ? 0 : 1;
}
