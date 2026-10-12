# CMakeList.txt : Top-level CMake project file, do global configuration
# and include sub-projects here.
#
cmake_minimum_required (VERSION 3.16)

# Enable Hot Reload for MSVC compilers if supported.
if (POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<IF:$<AND:$<C_COMPILER_ID:MSVC>,$<CXX_COMPILER_ID:MSVC>>,$<$<CONFIG:Debug,RelWithDebInfo>:EditAndContinue>,$<$<CONFIG:Debug,RelWithDebInfo>:ProgramDatabase>>")
endif()

project ("lua_fnmatch" VERSION 0.1.0 LANGUAGES C CXX)

if (CMAKE_SOURCE_DIR STREQUAL PROJECT_SOURCE_DIR)
  set(lua_fnmatch_top_level ON)
else()
  set(lua_fnmatch_top_level OFF)
endif()

option(LUA_FNMATCH_BUILD_TESTS "Register the Lua test suite with CTest" ${lua_fnmatch_top_level})

if (LUA_FNMATCH_BUILD_TESTS)
  enable_testing()
endif()

# Include sub-projects.
add_subdirectory ("lua_fnmatch")
