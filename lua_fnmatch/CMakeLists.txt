# CMakeList.txt : builds the `fnmatch` Lua module, and a static library for hosts that embed
# Lua and want to link the bindings in directly. The engine (engine/, Rust, over the
# stellar-fnmatch submodule) is built with cargo.
#
# Targets:
#   lua_fnmatch         (alias lua_fnmatch::module)  fnmatch.so / fnmatch.dll for require()
#   lua_fnmatch_static  (alias lua_fnmatch::static)  register `luaopen_fnmatch` yourself

if (NOT WIN32 AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "lua_fnmatch only supports Windows and Linux, not ${CMAKE_SYSTEM_NAME}.")
endif()

option(LUA_FNMATCH_BUILD_MODULE "Build the loadable module (fnmatch.so / fnmatch.dll)" ON)
option(LUA_FNMATCH_BUILD_STATIC "Build lua_fnmatch_static as part of the default target" OFF)
option(LUA_FNMATCH_RUST_STATIC_CRT "MSVC: build the engine with the static C runtime, for hosts built with /MT" OFF)
set(LUA_FNMATCH_LUA_INCLUDE_DIR "" CACHE PATH "Lua headers to build against. Empty: the LuaJIT submodule in lib/luajit")
set(LUA_FNMATCH_LUA_LIBRARY "" CACHE FILEPATH "Lua library to link: by the module on Windows, by the embedding test everywhere")
set(LUA_FNMATCH_LUA_INTERPRETER "" CACHE FILEPATH "Lua interpreter that runs the tests")
set(LUA_FNMATCH_LUAJIT_MAKE_ARGS "" CACHE STRING "Extra arguments for building the LuaJIT submodule with make")
set(LUA_FNMATCH_CARGO "" CACHE FILEPATH "cargo. Empty: from the PATH or ~/.cargo/bin")
set(LUA_FNMATCH_RUST_TARGET "" CACHE STRING "Rust target of the engine. Empty: the host's (x86_64-pc-windows-gnu with MinGW)")

find_package(Threads REQUIRED)

#
# Lua
#
# lua_include_dir   headers
# lua_library       what the module links against (Windows only, Linux modules resolve Lua
#                   symbols from the host process)
# lua_link_library  a library a host executable can link (for the embedding test)
# lua_interpreter   runs the tests
#

if (LUA_FNMATCH_LUA_INCLUDE_DIR)
  set(lua_include_dir "${LUA_FNMATCH_LUA_INCLUDE_DIR}")
  set(lua_link_library "${LUA_FNMATCH_LUA_LIBRARY}")
  set(lua_interpreter "${LUA_FNMATCH_LUA_INTERPRETER}")
  if (WIN32)
    set(lua_library "${LUA_FNMATCH_LUA_LIBRARY}")
    if (LUA_FNMATCH_BUILD_MODULE AND NOT lua_library)
      message(FATAL_ERROR
        "The module needs LUA_FNMATCH_LUA_LIBRARY on Windows (the import library of the Lua DLL, "
        "e.g. lua51.lib). Hosts that only link lua_fnmatch_static can set LUA_FNMATCH_BUILD_MODULE=OFF.")
    endif()
  endif()
elseif (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit/src/lua.h")
  include(ExternalProject)

  set(lua_include_dir "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit/src")
  set(luajit_dir "${CMAKE_CURRENT_BINARY_DIR}/luajit")

  if (MSVC)
    # msvcbuild.bat runs the tools it builds from the current directory, which cmd does not search
    # when NoDefaultCurrentDirectoryInExePath is set
    set(luajit_build_command ${CMAKE_COMMAND} -E chdir "${luajit_dir}/src"
        ${CMAKE_COMMAND} -E env --unset=NoDefaultCurrentDirectoryInExePath cmd /c msvcbuild.bat)
    set(lua_library "${luajit_dir}/src/lua51.lib")
    set(lua_link_library "${lua_library}")
    set(lua_interpreter "${luajit_dir}/src/luajit.exe")
  else()
    find_program(LUA_FNMATCH_MAKE NAMES gmake make mingw32-make)
    if (NOT LUA_FNMATCH_MAKE)
      message(FATAL_ERROR "make is needed to build the LuaJIT submodule")
    endif()
    cmake_host_system_information(RESULT cores QUERY NUMBER_OF_LOGICAL_CORES)
    set(luajit_make_args ${LUA_FNMATCH_LUAJIT_MAKE_ARGS})

    if (WIN32) # MinGW
      if (CMAKE_CROSSCOMPILING)
        get_filename_component(cc_name "${CMAKE_C_COMPILER}" NAME)
        string(REGEX REPLACE "gcc.*$" "" cross_prefix "${cc_name}")
        list(APPEND luajit_make_args HOST_CC=gcc CROSS=${cross_prefix} TARGET_SYS=Windows)
      endif()
      set(lua_library "${luajit_dir}/src/lua51.dll")
      set(lua_link_library "${lua_library}")
      set(lua_interpreter "${luajit_dir}/src/luajit.exe")
    else()
      set(lua_library "")
      set(lua_link_library "${luajit_dir}/src/libluajit.a" ${CMAKE_DL_LIBS} m)
      set(lua_interpreter "${luajit_dir}/src/luajit")
    endif()

    set(luajit_build_command ${LUA_FNMATCH_MAKE} -C "${luajit_dir}/src" -j${cores} ${luajit_make_args})
  endif()

  # Built from a copy so that the submodule's work tree stays clean.
  ExternalProject_Add(lua_fnmatch_luajit
    SOURCE_DIR "${luajit_dir}"
    DOWNLOAD_COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/lib/luajit" "${luajit_dir}"
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${luajit_build_command}
    BUILD_IN_SOURCE TRUE
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${lua_library} ${lua_interpreter} "${luajit_dir}/src/libluajit.a"
  )
  set(lua_dependency lua_fnmatch_luajit)
else()
  message(FATAL_ERROR
    "The LuaJIT submodule is missing. Run `git submodule update --init`, "
    "or point LUA_FNMATCH_LUA_INCLUDE_DIR at the Lua headers to build against.")
endif()

#
# The engine: a Rust static library built by cargo (always in release: the analysis is slow
# without optimizations)
#

set(engine_dir "${CMAKE_CURRENT_SOURCE_DIR}/engine")
if (NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/lib/stellar-fnmatch/Cargo.toml")
  message(FATAL_ERROR "The stellar-fnmatch submodule is missing. Run `git submodule update --init`.")
endif()

set(cargo "${LUA_FNMATCH_CARGO}")
if (NOT cargo)
  find_program(LUA_FNMATCH_CARGO_PATH NAMES cargo
    HINTS "$ENV{CARGO_HOME}/bin" "$ENV{HOME}/.cargo/bin" "$ENV{USERPROFILE}/.cargo/bin")
  set(cargo "${LUA_FNMATCH_CARGO_PATH}")
endif()
if (NOT cargo)
  message(FATAL_ERROR "cargo is needed to build the engine (https://rustup.rs), or set LUA_FNMATCH_CARGO")
endif()

set(rust_target "${LUA_FNMATCH_RUST_TARGET}")
if (NOT rust_target AND MINGW)
  set(rust_target x86_64-pc-windows-gnu)
endif()
set(engine_target_dir "${CMAKE_CURRENT_BINARY_DIR}/engine")
if (rust_target)
  set(engine_target_args --target ${rust_target})
  set(engine_out "${engine_target_dir}/${rust_target}/release")
else()
  set(engine_target_args "")
  set(engine_out "${engine_target_dir}/release")
endif()
if (MSVC)
  set(engine_lib "${engine_out}/lua_fnmatch_engine.lib")
else()
  set(engine_lib "${engine_out}/liblua_fnmatch_engine.a")
endif()

set(engine_env "CARGO_TARGET_DIR=${engine_target_dir}")
if (LUA_FNMATCH_RUST_STATIC_CRT)
  list(APPEND engine_env "RUSTFLAGS=-C target-feature=+crt-static")
endif()

# cargo decides itself whether anything changed
add_custom_target(lua_fnmatch_engine_build
  COMMAND ${CMAKE_COMMAND} -E env ${engine_env}
          "${cargo}" build --release --manifest-path "${engine_dir}/Cargo.toml" ${engine_target_args}
  BYPRODUCTS "${engine_lib}"
  WORKING_DIRECTORY "${engine_dir}"
  COMMENT "Building the fnmatch engine (cargo)"
  USES_TERMINAL
  VERBATIM
)

# What the Rust standard library needs from the system (`--print native-static-libs`)
add_library(lua_fnmatch_engine INTERFACE)
target_include_directories(lua_fnmatch_engine INTERFACE "${engine_dir}/include")
target_link_libraries(lua_fnmatch_engine INTERFACE "${engine_lib}")
if (WIN32)
  target_link_libraries(lua_fnmatch_engine INTERFACE kernel32 advapi32 ntdll userenv ws2_32 dbghelp bcrypt)
else()
  target_link_libraries(lua_fnmatch_engine INTERFACE Threads::Threads ${CMAKE_DL_LIBS} m rt util gcc_s)
endif()

#
# bundle.lua (fnmatch.bundle) is compiled into the module as a byte array
#

set(embedded_lua_source "${CMAKE_CURRENT_SOURCE_DIR}/bundle.lua")
set(embedded_lua_name "lua_fnmatch_bundle_lua")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${embedded_lua_source}")
file(READ "${embedded_lua_source}" embedded_lua_hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," embedded_lua_bytes "${embedded_lua_hex}")
string(REPEAT "0x..," 16 embedded_lua_line) # CMake regexes have no {n}
string(REGEX REPLACE "(${embedded_lua_line})" "\\1\n" embedded_lua_bytes "${embedded_lua_bytes}")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/embedded_lua.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/lua_fnmatch_bundle.h" @ONLY)

#
# Build settings shared by the module and the static library. Linked privately: consumers of
# the static library only see lua_fnmatch.h and the Lua headers.
#

add_library(lua_fnmatch_config INTERFACE)
target_include_directories(lua_fnmatch_config INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/generated"
  "${lua_include_dir}"
)
target_compile_features(lua_fnmatch_config INTERFACE cxx_std_17)
target_compile_definitions(lua_fnmatch_config INTERFACE LUA_FNMATCH_VERSION="${lua_fnmatch_VERSION}")
target_link_libraries(lua_fnmatch_config INTERFACE lua_fnmatch_engine)
if (MSVC)
  target_compile_options(lua_fnmatch_config INTERFACE /utf-8 /Zc:__cplusplus)
  if (NOT LUA_FNMATCH_RUST_STATIC_CRT)
    # the engine uses the release DLL runtime; debug builds use the debug one
    target_link_options(lua_fnmatch_config INTERFACE $<$<CONFIG:Debug>:/NODEFAULTLIB:msvcrt.lib>)
  endif()
endif()

if (MSVC)
  set(lua_fnmatch_warnings /W4)
else()
  set(lua_fnmatch_warnings -Wall -Wextra -Wpedantic)
endif()

#
# Lua module: require("fnmatch")
#

if (LUA_FNMATCH_BUILD_MODULE)
  add_library(lua_fnmatch MODULE "lua_fnmatch.cpp" "lua_fnmatch.h")
  add_library(lua_fnmatch::module ALIAS lua_fnmatch)
  set_target_properties(lua_fnmatch PROPERTIES
    OUTPUT_NAME "fnmatch"
    PREFIX ""
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
  )
  target_compile_definitions(lua_fnmatch PRIVATE LUA_FNMATCH_BUILDING)
  target_compile_options(lua_fnmatch PRIVATE ${lua_fnmatch_warnings})
  target_link_libraries(lua_fnmatch PRIVATE lua_fnmatch_config)
  add_dependencies(lua_fnmatch lua_fnmatch_engine_build)
  if (lua_library)
    target_link_libraries(lua_fnmatch PRIVATE "${lua_library}")
  endif()
  if (NOT MSVC)
    # export luaopen_fnmatch only, not the engine's symbols
    target_link_options(lua_fnmatch PRIVATE -Wl,--exclude-libs,ALL)
  endif()
  if (MINGW)
    # No libstdc++ / libgcc / winpthread DLLs needed next to fnmatch.dll
    target_link_options(lua_fnmatch PRIVATE -static)
  endif()
  if (lua_dependency)
    add_dependencies(lua_fnmatch ${lua_dependency})
  endif()
endif()

#
# Static library: link it into a host and register `luaopen_fnmatch`
#

add_library(lua_fnmatch_static STATIC "lua_fnmatch.cpp" "lua_fnmatch.h")
add_library(lua_fnmatch::static ALIAS lua_fnmatch_static)
set_target_properties(lua_fnmatch_static PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(lua_fnmatch_static PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}" "${lua_include_dir}")
target_compile_definitions(lua_fnmatch_static PUBLIC LUA_FNMATCH_STATIC)
target_compile_options(lua_fnmatch_static PRIVATE ${lua_fnmatch_warnings})
target_link_libraries(lua_fnmatch_static PRIVATE lua_fnmatch_config)
add_dependencies(lua_fnmatch_static lua_fnmatch_engine_build)
if (lua_dependency)
  add_dependencies(lua_fnmatch_static ${lua_dependency})
endif()
if (NOT LUA_FNMATCH_BUILD_STATIC)
  set_target_properties(lua_fnmatch_static PROPERTIES EXCLUDE_FROM_ALL TRUE)
endif()

#
# Tests
#

if (LUA_FNMATCH_BUILD_TESTS)
  add_subdirectory(tests)
endif()
