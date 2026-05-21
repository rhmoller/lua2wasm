cmake_minimum_required(VERSION 3.25)
project(lua2wasm C)

set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug)
endif()

add_compile_options(-Wall -Wextra -Wpedantic -Wno-unused-parameter)

set(COMPILER_SOURCES
    src/ast.c
    src/lexer.c
    src/parser.c
    src/wat_builder.c
    src/codegen.c
    src/builtins.c
    src/xalloc.c
)

add_library(lua2wasm_core STATIC ${COMPILER_SOURCES})
target_include_directories(lua2wasm_core PUBLIC src)
# `#embed "prelude.wat"` in codegen.c — clang's #embed search uses its own
# --embed-dir= flag, not -I. Point it at runtime/ so both native and
# emscripten builds find it.
target_compile_options(lua2wasm_core PRIVATE --embed-dir=${CMAKE_SOURCE_DIR}/runtime)
# Re-link when the embedded prelude changes.
set_source_files_properties(src/codegen.c PROPERTIES
    OBJECT_DEPENDS ${CMAKE_SOURCE_DIR}/runtime/prelude.wat)

add_executable(lua2wasm src/main.c)
target_link_libraries(lua2wasm PRIVATE lua2wasm_core)

# --- µnit tests ---------------------------------------------------------
enable_testing()

add_library(munit STATIC third_party/munit/munit.c)
target_include_directories(munit PUBLIC third_party/munit)
# munit predates C23 (uses removed ATOMIC_VAR_INIT). Build it as C11.
set_source_files_properties(third_party/munit/munit.c PROPERTIES
    LANGUAGE C
    COMPILE_FLAGS "-std=c11 -Wno-pedantic -Wno-extra")

function(add_unit_test name file)
    add_executable(${name} ${file})
    target_link_libraries(${name} PRIVATE lua2wasm_core munit)
    add_test(NAME ${name} COMMAND ${name})
endfunction()

add_unit_test(test_lexer   tests/test_lexer.c)
add_unit_test(test_parser  tests/test_parser.c)
add_unit_test(test_codegen tests/test_codegen.c)

# --- End-to-end test ----------------------------------------------------
add_test(
    NAME test_e2e_print_sum
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

# Data-driven e2e suite: one ctest per row of tests/e2e/manifest.tsv,
# each compiling a fixture and diffing stdout against its golden in
# tests/e2e/expected/. Regenerate goldens with tests/e2e/regen.sh.
file(STRINGS ${CMAKE_SOURCE_DIR}/tests/e2e/manifest.tsv _e2e_rows)
foreach(_row ${_e2e_rows})
    if(_row MATCHES "^#" OR _row STREQUAL "")
        continue()
    endif()
    string(REPLACE "\t" ";" _parts "${_row}")
    list(GET _parts 0 _e2e_name)
    list(GET _parts 1 _e2e_fixture)
    add_test(
        NAME test_e2e_${_e2e_name}
        COMMAND bash ${CMAKE_SOURCE_DIR}/tests/e2e/run.sh
                $<TARGET_FILE:lua2wasm> ${CMAKE_SOURCE_DIR} ${CMAKE_BINARY_DIR}
                ${_e2e_name} ${_e2e_fixture})
endforeach()

# E2E tests that need custom drivers (stdin, stderr capture, -m modules,
# multiple compiler invocations, or multi-fixture sweeps) keep their own
# scripts under tests/.
add_test(
    NAME test_e2e_attributes
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_attributes.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_io_read
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_io_read.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_io_read_full
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_io_read_full.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_milestone25
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone25.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_module_shebang
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_module_shebang.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_read_file_errors
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_read_file_errors.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_os_lib
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_os_lib.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_samples
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_samples.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_xpcall_warn
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_xpcall_warn.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_host_format
    COMMAND node --test ${CMAKE_SOURCE_DIR}/tests/test_host_format.mjs
)

add_test(
    NAME test_playground_presets_in_sync
    COMMAND node ${CMAKE_SOURCE_DIR}/scripts/bundle-presets.mjs --check
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

# Differential check vs reference Lua 5.5 (golden files in tests/diff/expected,
# captured via `scripts/diff-test.sh --regen` on a host with lua5.5). Check mode
# needs no lua5.5: it diffs compiled output against the checked-in goldens.
# `pass` cases guard against regressions; `xfail` cases are captured bugs and
# turn this test red if one starts matching again (promote it to `pass`).
add_test(
    NAME test_diff_reference
    COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/diff-test.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
