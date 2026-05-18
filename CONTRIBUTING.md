# Contributing to lua2wasm

Thanks for being here. This project is small enough that there isn't a
formal process — these notes just save the next person an evening of
guessing.

## Building & testing

```sh
cmake -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

You need:
- Clang 19+ (for C23 `#embed` of the runtime prelude)
- CMake ≥ 3.25, Ninja or Make
- [Binaryen](https://github.com/WebAssembly/binaryen)'s `wasm-as` on `$PATH`
- Node 22+ for the host runner (`runtime/host.mjs`) and the playground

Everything below is enforced by `ctest` — get to a green run before
opening a PR.

## The phase rule

> *If you can't print it, you didn't build it.*

New language features land behind an end-to-end fixture **before** they
land as syntax in the parser. A typical landing pattern:

1. Write a `tests/fixtures/<feature>.lua` that prints something the new
   feature is needed for.
2. Add `tests/test_e2e_<feature>.sh` (or an expected-output file under
   `tests/expected/`) and wire it into `CMakeLists.txt`.
3. Confirm the test fails for the right reason.
4. Implement lexer → parser → codegen until it passes.
5. Land the fixture, harness, and implementation in one commit.

Bug fixes follow the same shape: failing test first, fix second, both
in the same commit.

## Style

- C23. Build with `-Wall -Wextra -Wpedantic` and keep them clean.
- Two-space indents. Match the surrounding file.
- The runtime prelude lives in `runtime/prelude.wat` and is embedded
  via C23 `#embed`. Edit it as WAT, not as a C string.
- Codegen helpers like `emit_args_array` exist to be reused — prefer
  them over open-coding the same multi-value pattern again.
- No emoji in source or commit messages unless asked.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/). The types
used in this repo:

| type       | when                                                       |
|------------|------------------------------------------------------------|
| `feat:`    | new language feature, new builtin, new flag                |
| `fix:`     | bug fix that ships with a regression test                  |
| `refactor:`| no behaviour change                                        |
| `test:`    | tests only                                                 |
| `docs:`    | docs only (`README.md`, `GOAL.md`, this file, comments)    |
| `chore:`   | build, gitignore, formatter config                         |
| `build:`   | CMake, scripts                                             |

A scope helps when the diff isn't obvious from the subject, e.g.
`feat(parser): handle long-string literals` or
`fix(codegen): unbox non-captured locals`.

No AI-attribution trailers (no `Co-Authored-By: Claude`).

## Testing layout

- `tests/test_lexer.c`, `tests/test_parser.c`, `tests/test_codegen.c`
  — µnit unit tests (positive cases and a growing set of negatives).
- `tests/test_e2e_*.sh` — end-to-end: compile → `wasm-as` → run under
  Node, compare against either an inline string or
  `tests/expected/<name>.txt`. New tests should prefer the expected-file
  form so output can be edited as plain text.
- `tests/test_host_format.mjs` — `node --test` for the JS-side number
  formatters (`runtime/format.mjs`).

## Pull requests

- One topic per PR. If a refactor and a feature both belong, two PRs.
- The full `ctest` matrix must be green.
- Mention the punch-list item from `notes/codereview.md` if your change
  closes one — that file is the rolling backlog.

## License

By contributing you agree your changes ship under the project's MIT
license.
