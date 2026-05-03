---
description: ALWAYS invoke this skill when the user asks to generate, create, build, or write a JSONata expression / .jsonata file from a pair of input and output JSON files. Trigger phrases include "generate jsonata", "create jsonata", "jsonata from input/output", "transform input to output with jsonata".
---

# Generate a JSONata expression that maps input.json → output.json

The user has two JSON files (an input and a desired output) and wants a single JSONata expression that, when applied to the input, produces the output. The arguments are: `$ARGUMENTS` — typically two file paths, the first is the input and the second is the desired output. If a third path is given, write the result there; otherwise default to `<output-name>.jsonata` next to the output file.

## Hard requirements

1. **Key order in every produced object must match the target output exactly.** JSONata preserves the literal order of keys you write inside `{ ... }`, so build each object literal by listing its keys in the same order as the target. Do not reorder, alphabetize, or use a generic `$merge`-style construct that loses ordering.
2. **Array element order must match the target exactly.** When mapping an input array, preserve the original index order. If the target reorders, sort, dedupes, or filters elements, encode that explicitly with `^(...)`, `[? predicate ]`, or `$distinct`.
3. **The expression must be a single JSONata file** — no JavaScript, no helper scripts. Multi-line is fine; comments (`/* ... */`) are encouraged for any non-obvious mapping.
4. **No extra keys, no missing keys.** The produced output must equal the target structurally and value-wise. Do not invent fields the target doesn't have, even if they exist in the input.

## Procedure

1. Read both files with `Read`. Note the absolute paths.
2. Build a mapping table mentally: for every leaf value in the target output, identify whether it (a) comes verbatim from a path in the input, (b) is a transformation (concat, math, type cast, lookup), or (c) is a constant.
3. Walk the target output **top-down**. For each object, write a JSONata `{ ... }` block whose keys appear in the same textual order as the target. For each array, write a `$map` / `[...]` that preserves index order (or apply explicit ordering when needed).
4. Write the expression to a `.jsonata` file using the `Write` tool. Path: third argument if provided, else `<dirname-of-output>/<basename-of-output-without-.json>.jsonata`.
5. **Verify the output.** Run the expression against the input and diff against the target:

   ```powershell
   # If jsonata-cli is on PATH:
   jsonata -e (Get-Content <generated>.jsonata -Raw) (Get-Content <input>.json -Raw) > <tmp>.json
   # Or via npx (no install required):
   npx -y jsonata-cli "$(Get-Content <generated>.jsonata -Raw)" --input <input>.json > <tmp>.json
   ```

   Compare with `<output>.json`. If `jsonata-cli` is not available, ask the user to install it (`npm i -g jsonata-cli`) — do not skip verification silently.
6. If the diff is non-empty: identify the first divergent path, fix the JSONata for that path only, and re-verify. Repeat until the diff is empty.
7. Report: the path of the written `.jsonata` file, whether verification passed, and the verification command you ran. If verification was skipped (e.g. tool unavailable), say so explicitly.

## Common pitfalls — check these before claiming success

- **Key reordering by accident.** A pattern like `input ~> | $ | { ... } |` performs a *merge*, which can silently reorder keys. Use plain `{ "a": ..., "b": ... }` instead, listing keys in the target's order.
- **`$each` returns an array, not an object.** Use `$reduce` or explicit object literals when a target object's key set depends on input values.
- **Numbers vs. strings.** JSONata does not auto-cast — `$number(x)` and `$string(x)` are explicit. Diff failures often trace to a quoted "42" in the target where the input had `42` (or vice versa).
- **Empty arrays vs. missing keys.** `[]` and "key absent" produce different JSON. Match what the target has.
- **Singleton arrays.** `array[0]` returns the scalar; use `[ array[0] ]` if the target wants a one-element array.
