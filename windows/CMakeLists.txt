# KBSwitch for Windows. Usually built by GitHub Actions (see .github/workflows/build.yml);
# locally: .\build.ps1  (Visual Studio Build Tools with "Desktop development with C++" + CMake).
cmake_minimum_required(VERSION 3.16)
project(KBSwitch LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(HUNSPELL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../hunspell)
file(GLOB HUNSPELL_SOURCES ${HUNSPELL_DIR}/*.cxx)

add_executable(KBSwitch WIN32 kbswitch.cpp kbswitch.rc ${HUNSPELL_SOURCES})
target_include_directories(KBSwitch PRIVATE ${HUNSPELL_DIR})
target_compile_definitions(KBSwitch PRIVATE HUNSPELL_STATIC UNICODE _UNICODE)
target_link_libraries(KBSwitch PRIVATE ole32 oleaut32 uuid comctl32 shell32 advapi32 user32 gdi32)

if(MSVC)
  target_compile_options(KBSwitch PRIVATE /utf-8 /W3 /O2)
  # Static C runtime: the exe runs without installing any Visual C++ redistributable.
  set_property(TARGET KBSwitch PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
  # The manifest is embedded by kbswitch.rc.
  target_link_options(KBSwitch PRIVATE /MANIFEST:NO)
else()
  target_link_options(KBSwitch PRIVATE -municode -static)
endif()
