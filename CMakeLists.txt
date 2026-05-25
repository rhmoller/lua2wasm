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

# wat2wasm: a standalone WAT -> wasm binary assembler. Self-contained (no
# dependency on lua2wasm_core or the runtime), so it links cleanly into both
# the lua2wasm compiler (for direct -o .wasm output) and its own CLI.
add_library(wat2wasm_core STATIC src/wat2wasm.c)
target_include_directories(wat2wasm_core PUBLIC src)

add_executable(wat2wasm src/wat2wasm_cli.c)
target_link_libraries(wat2wasm PRIVATE wat2wasm_core)

# lua2wasm emits WAT by default and a binary module directly (via the
# wat2wasm assembler) when the output path ends in .wasm.
add_executable(lua2wasm src/main.c)
target_link_libraries(lua2wasm PRIVATE lua2wasm_core wat2wasm_core)

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

# Flag-on pass: re-run every e2e fixture with the numeric/call specialization
# enabled (LUA2WASM_OPT_INT=1), diffing against the *same* default golden — the
# optimized codegen must be behaviour-identical. This guards an otherwise
# 0%-covered code path (a CRAP analysis flagged it). _e2e_opt_skip lists cases
# whose flag-on output legitimately differs (e.g. error-message text the project
# matches only semantically); currently empty.
set(_e2e_opt_skip)
foreach(_row ${_e2e_rows})
    if(_row MATCHES "^#" OR _row STREQUAL "")
        continue()
    endif()
    string(REPLACE "\t" ";" _parts "${_row}")
    list(GET _parts 0 _e2e_name)
    list(GET _parts 1 _e2e_fixture)
    if(_e2e_name IN_LIST _e2e_opt_skip)
        continue()
    endif()
    add_test(
        NAME test_e2e_opt_${_e2e_name}
        COMMAND bash ${CMAKE_SOURCE_DIR}/tests/e2e/run.sh
                $<TARGET_FILE:lua2wasm> ${CMAKE_SOURCE_DIR} ${CMAKE_BINARY_DIR}
                opt_${_e2e_name} ${_e2e_fixture} ${_e2e_name})
    set_tests_properties(test_e2e_opt_${_e2e_name} PROPERTIES
                         ENVIRONMENT "LUA2WASM_OPT_INT=1")
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
    NAME test_e2e_tree_shake_bootstrap
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_tree_shake_bootstrap.sh
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
    NAME test_e2e_binary_string
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_binary_string.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
add_test(
    NAME test_e2e_const_upvalue
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_const_upvalue.sh
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
    NAME test_e2e_global_attr_reject
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_global_attr_reject.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_host_format
    COMMAND node --test ${CMAKE_SOURCE_DIR}/tests/test_host_format.mjs
)

# wat2wasm assembler: TDD harness. Each case assembles a tiny WAT module with
# our wat2wasm, instantiates it under Node, and asserts behavior; when wasm-as
# is on PATH it cross-checks against that reference assembler.
find_program(WASM_AS_PROG NAMES wasm-as)
# --test-isolation=none keeps the run in this process so the
# --experimental-wasm-exnref V8 flag applies to the WebAssembly compiles
# (the test runner does not forward it to per-file child processes).
add_test(
    NAME test_wat2wasm
    COMMAND node --experimental-wasm-exnref --test --test-isolation=none
            ${CMAKE_SOURCE_DIR}/tests/wat2wasm/run.mjs
)
if(WASM_AS_PROG)
    set_tests_properties(test_wat2wasm PROPERTIES ENVIRONMENT
        "WAT2WASM=$<TARGET_FILE:wat2wasm>;WASM_AS=${WASM_AS_PROG}")
else()
    set_tests_properties(test_wat2wasm PROPERTIES ENVIRONMENT
        "WAT2WASM=$<TARGET_FILE:wat2wasm>")
endif()

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

# --- formatting ---------------------------------------------------------
# `format` rewrites src/ in place; `format-check` fails if anything is unformatted.
# Both are no-ops on machines without clang-format. The .clang-format config and
# the optional .githooks/pre-commit hook (git config core.hooksPath .githooks)
# are the source of truth for C style.
find_program(CLANG_FORMAT NAMES clang-format)
if(CLANG_FORMAT)
    file(GLOB FORMAT_SOURCES CONFIGURE_DEPENDS
        ${CMAKE_SOURCE_DIR}/src/*.c ${CMAKE_SOURCE_DIR}/src/*.h)
    add_custom_target(format
        COMMAND ${CLANG_FORMAT} -i ${FORMAT_SOURCES}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "clang-format -i src/*.{c,h}")
    add_custom_target(format-check
        COMMAND ${CLANG_FORMAT} --dry-run -Werror ${FORMAT_SOURCES}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "clang-format --dry-run -Werror (fails if unformatted)")
endif()
