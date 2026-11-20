# Builds ZONOS3-Mini's C++ runtime (a checkout given as ZONOS_SRC) together with the small C
# bridge the app uses: the libraries behind zb.cpp, and the model's own server as a library
# (zb_server.cpp starts it inside the app). The tools and the desktop app are not built.
cmake_minimum_required(VERSION 3.22)
project(zb CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if (NOT ZONOS_SRC)
    message(FATAL_ERROR "pass -DZONOS_SRC=<checkout of github.com/Zyphra/ZONOS3-Mini>")
endif()
add_subdirectory(${ZONOS_SRC}/servers/ggml zonos3 EXCLUDE_FROM_ALL)
# The server's main.cpp is compiled without its main(): zb_server.cpp calls zonos3_server_main.
add_library(zb STATIC zb.cpp zb_voice.cpp zb_server.cpp ${ZONOS_SRC}/servers/ggml/src/server/main.cpp)
target_compile_definitions(zb PRIVATE ZONOS3_APP_EMBED)
target_include_directories(zb PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(zb PUBLIC zonos3-server-core zonos3 zonos3-audio)
if (NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(zb-test zb_test.cpp)
    target_link_libraries(zb-test PRIVATE zb)
    # The embedded server, kept running for a check from outside (the same code the phone runs).
    add_executable(zb-serve zb_serve.cpp)
    target_link_libraries(zb-serve PRIVATE zb)
    # The measurement for a desktop computer with a graphics card (pc/OLCUM.bat runs it).
    add_executable(zb-pc zb_pc.cpp)
    target_link_libraries(zb-pc PRIVATE zb)
    # The spoken translation on a desktop computer (pc/BASLAT.bat runs it): waits at the TV for Turkish
    # lines, speaks them in the character's voice and hands the sound back.
    add_executable(tr-altyazi-ses zb_pc_voice.cpp)
    target_link_libraries(tr-altyazi-ses PRIVATE zb)
endif()
if (MSVC)
    # Our sources are UTF-8 (Turkish test lines).
    target_compile_options(zb PUBLIC /utf-8)
endif()
