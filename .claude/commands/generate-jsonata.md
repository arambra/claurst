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
5. **Verify with a key-order-aware comparison.** Run the expression against the input, then diff the canonicalized result against the target. Value-only structural diffs (e.g. `Compare-Object` on parsed objects, `jq -e '. == .'`) silently miss key reorderings and **must not be used** — they would let a regression on Hard Requirement #1 pass undetected.

   Two pitfalls to avoid:
   - `npx -y jsonata-cli "<expr>"` passes the whole expression as a CLI argument, which blows past the Windows `cmd.exe` 8 KB limit for non-trivial expressions. Use a Node helper that reads the `.jsonata` file from disk instead (see below).
   - PowerShell's `-eq`/`-ceq` operators on multi-line strings act as **filters**, not boolean comparators, when stdout is captured as an array of lines. Compare canonicalized files via hash or via `git diff --no-index` for an unambiguous boolean.

   ```powershell
   # 1. Make sure the jsonata package is available to Node (one-time per repo).
   #    Cheapest way: install once locally; on a fresh checkout `npm install`
   #    will pull it from package.json if you save it as a devDependency.
   if (-not (Test-Path node_modules/jsonata)) { npm install --no-save jsonata }

   # 2. Evaluate the expression via a small ESM helper that reads the .jsonata
   #    from disk (bypasses the Windows command-line length limit). Write the
   #    helper once, reuse forever:
   #
   #       // tools/run-jsonata.mjs
   #       import { readFileSync } from 'node:fs';
   #       import jsonata from 'jsonata';
   #       const [exprPath, inputPath] = process.argv.slice(2);
   #       const expr  = readFileSync(exprPath, 'utf8');
   #       const input = JSON.parse(readFileSync(inputPath, 'utf8'));
   #       const result = await jsonata(expr).evaluate(input);
   #       process.stdout.write(JSON.stringify(result, null, 2));
   #
   node tools/run-jsonata.mjs <generated>.jsonata <input>.json > <generated>.json

   # 3. Canonicalize both target and generated. Node's JSON.parse + JSON.stringify
   #    preserves the insertion order of object keys (ECMAScript spec — string
   #    keys are enumerated in insertion order), so any key-order divergence at
   #    any nesting depth shows up as a textual difference.
   $canon = {
       param($p)
       node -e "process.stdout.write(JSON.stringify(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')), null, 2))" "$p"
   }
   & $canon <output>.json    | Out-File _expected.canon.json -Encoding utf8 -NoNewline
   & $canon <generated>.json | Out-File _generated.canon.json -Encoding utf8 -NoNewline

   # 4. Hash compare — unambiguous boolean, no PowerShell array-vs-string traps.
   $expHash = (Get-FileHash _expected.canon.json -Algorithm SHA256).Hash
   $genHash = (Get-FileHash _generated.canon.json -Algorithm SHA256).Hash
   if ($expHash -eq $genHash) {
       Write-Host "verified: key order and values match"
       Remove-Item _expected.canon.json, _generated.canon.json
   } else {
       Write-Host "MISMATCH — first divergent lines:"
       git --no-pager diff --no-index --no-color _expected.canon.json _generated.canon.json
   }
   ```

   If `node` or the `jsonata` npm package isn't available, ask the user to install (Node 18+ and `npm install jsonata`) — do not skip verification silently. The standalone `jsonata-cli` binary works for tiny expressions but is not safe on Windows past ~8 KB; prefer the Node-helper path universally.
6. If the canonicalized diff is non-empty: identify the first divergent line, trace it back to its JSONata source (key reorder in step 3, value transform, missing/extra key), fix that one location in the `.jsonata` file, and re-run step 5. Repeat until `$expected -ceq $generated` holds.
7. Report: the path of the written `.jsonata` file, whether verification passed, and the verification command you ran. If verification was skipped (e.g. tool unavailable), say so explicitly.

## Common pitfalls — check these before claiming success

- **Key reordering by accident.** A pattern like `input ~> | $ | { ... } |` performs a *merge*, which can silently reorder keys. Use plain `{ "a": ..., "b": ... }` instead, listing keys in the target's order.
- **`$each` returns an array, not an object.** Use `$reduce` or explicit object literals when a target object's key set depends on input values.
- **Numbers vs. strings.** JSONata does not auto-cast — `$number(x)` and `$string(x)` are explicit. Diff failures often trace to a quoted "42" in the target where the input had `42` (or vice versa).
- **Empty arrays vs. missing keys.** `[]` and "key absent" produce different JSON. Match what the target has.
- **Singleton arrays.** `array[0]` returns the scalar; use `[ array[0] ]` if the target wants a one-element array.
