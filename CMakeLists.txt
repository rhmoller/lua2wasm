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

add_test(
    NAME test_e2e_milestone2
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone2.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone3
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone3.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone3b
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone3b.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone4
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone4.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone5
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone5.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone6
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone6.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone7
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone7.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_milestone8
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_milestone8.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_print_multiarg
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_print_multiarg.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_builtins_basic
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_builtins_basic.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_rawequal
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_rawequal.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_rawlen
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_rawlen.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_rawget
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_rawget.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_rawset
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_rawset.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_table_pack
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_pack.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_table_move
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_move.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_table_create
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_create.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_case
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_case.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_reverse
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_reverse.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_rep
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_rep.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_byte
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_byte.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_char
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_char.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_math_deg_rad
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_math_deg_rad.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_math_fillers
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_math_fillers.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_math_atan_log
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_math_atan_log.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_math_random
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_math_random.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_mod_floor
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_mod_floor.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_fdiv_floor
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_fdiv_floor.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_pow
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_pow.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_tonumber
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_tonumber.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_concat_typecheck
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_concat_typecheck.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_compare_typecheck
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_compare_typecheck.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_char
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_char.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_charpattern
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_charpattern.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_len
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_len.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_codepoint
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_codepoint.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_offset
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_offset.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_utf8_codes
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_utf8_codes.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_format_full
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_format_full.sh
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
    NAME test_e2e_table_sort
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_sort.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_metamethods_arith
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_metamethods_arith.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_metamethods_concat_len
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_metamethods_concat_len.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_metamethods_lt_le
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_metamethods_lt_le.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_metamethods_ni_ts_mt
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_metamethods_ni_ts_mt.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_hex_literals
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_hex_literals.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_escapes
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_escapes.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_long_brackets
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_long_brackets.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_goto_label
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_goto_label.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_bitwise
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_bitwise.sh
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
    NAME test_e2e_globals_G
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_globals_G.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_find_basic
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_find_basic.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_captures
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_captures.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_match
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_match.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_balanced_frontier
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_balanced_frontier.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_gmatch
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_gmatch.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_gsub_string
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_gsub_string.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_gsub_repl
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_gsub_repl.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_patterns_soak
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_patterns_soak.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_method_sugar
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_method_sugar.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_math_table_lib
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_math_table_lib.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_string_format
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_string_format.sh
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
    NAME test_e2e_implicit_globals
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_implicit_globals.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_tutorial_gaps
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_tutorial_gaps.sh
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
    NAME test_e2e_iterator
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_iterator.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_varargs
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_varargs.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_table_unpack
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_unpack.sh
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

add_test(
    NAME test_e2e_nan_key
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_nan_key.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_no_capture_loop
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_no_capture_loop.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_call_typing
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_call_typing.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_table_hash
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_table_hash.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)

add_test(
    NAME test_e2e_for_step_zero
    COMMAND bash ${CMAKE_SOURCE_DIR}/tests/test_e2e_for_step_zero.sh
            $<TARGET_FILE:lua2wasm>
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_BINARY_DIR}
)
