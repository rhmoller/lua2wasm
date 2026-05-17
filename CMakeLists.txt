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
)

add_library(lua2wasm_core STATIC ${COMPILER_SOURCES})
target_include_directories(lua2wasm_core PUBLIC src)

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
