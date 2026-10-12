# The test suite runs twice: with the module loaded by `require` from the interpreter, and with
# the static library linked into a host program that preloads it (`lua_fnmatch_embed_host`).
#
# The script's arguments are the directory of the module (for package.cpath, empty when it is
# preloaded) and the fixtures directory.

set(test_script "${CMAKE_CURRENT_SOURCE_DIR}/test_fnmatch.lua")
set(fixtures "${CMAKE_CURRENT_SOURCE_DIR}/fixtures")

if (lua_interpreter AND TARGET lua_fnmatch)
  add_test(NAME lua_fnmatch_module
    COMMAND "${lua_interpreter}" "${test_script}" "$<TARGET_FILE_DIR:lua_fnmatch>" "${fixtures}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
  )
else()
  message(STATUS "lua_fnmatch: no module or no Lua interpreter (LUA_FNMATCH_LUA_INTERPRETER), the module test is not registered")
endif()

if (lua_link_library)
  add_executable(lua_fnmatch_embed_host "embed_host.cpp")
  target_link_libraries(lua_fnmatch_embed_host PRIVATE lua_fnmatch_static ${lua_link_library})
  if (lua_dependency)
    add_dependencies(lua_fnmatch_embed_host ${lua_dependency})
  endif()
  if (MINGW)
    target_link_options(lua_fnmatch_embed_host PRIVATE -static)
  endif()
  if (WIN32 AND lua_dependency)
    # The bundled LuaJIT is a DLL on Windows
    add_custom_command(TARGET lua_fnmatch_embed_host POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${luajit_dir}/src/lua51.dll" "$<TARGET_FILE_DIR:lua_fnmatch_embed_host>"
    )
  endif()

  add_test(NAME lua_fnmatch_embedded
    COMMAND lua_fnmatch_embed_host "${test_script}" "" "${fixtures}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
  )
else()
  message(STATUS "lua_fnmatch: no linkable Lua library (LUA_FNMATCH_LUA_LIBRARY), the embedding test is not registered")
endif()
