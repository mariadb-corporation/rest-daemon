# V8 as the script engine (plan)

Status: **proposal, not decided** (2026-10-30). Replaces GraalVM (GraalJS, native
image) with V8 as the JavaScript engine of the JIT executor plugin, which runs
MRS scripts (`content_set_def` endpoints).

## Why

- **Platforms.** GraalVM Community has no Windows ARM64 build and none is
  planned ([oracle/graal#9215](https://github.com/oracle/graal/issues/9215),
  "not on our roadmap", 2026-01). Our Windows ARM64 package is the x64 one, run
  under emulation. GraalVM also dropped macOS x64 after 25.0.0, so the next
  GraalVM upgrade would cost us the macOS x64 package. V8 builds natively for
  all six targets.
- **Build.** The JIT executor library is a GraalVM native image: Maven, a 20 GB
  heap, minutes per platform, 2,653 lines of patches on GraalVM's polyglot
  native API (`ext/polyglot`). With V8 the plugin links a prebuilt static
  library.
- **Licensing.** The GraalVM and OpenJDK notices are the bulk of the LICENSE
  file (section B.1 of legal's review). V8 is BSD-3; its third-party notices
  are short.
- **Debugging.** Unchanged in substance: VS Code attaches to the engine over
  CDP (`"type": "node"`, port 9229), and V8's inspector is the reference
  implementation of CDP. We supply only the WebSocket transport. Source maps
  for TypeScript are resolved by VS Code either way.

The move to GraalVM was not technical; the MRS scripts use nothing
GraalJS-specific (confirmed 2026-10-30).

## What stays and what changes

The engine is behind one interface, and the REST service plugin uses only it
(6 files in `src/mysql_rest_service`): `JitExecutorComponent::get_context`,
`IContext::execute`, `ServiceHandlerConfig`, `GlobalCallbacks`, `IFile_system`.
**That interface stays as it is**, so the REST service plugin, its tests, the
content-set file system (`mrs/file_system/db_service_file_system.cc`) and the
`_debug` handler don't change. The script contract stays too (`mrs.d.ts` in the
shell plugins: `print`, `SqlError`, `Session.runSql`, `getSession`,
`getCurrentMrsUserId`, `getContentSetPath`; ES modules; promises resolved;
JSON or raw results).

Inside `src/jit_executor` (21,000 lines without tests), 18 files call
GraalVM's `poly_*` API. The rest, above all `jit_executor_value.cc` (1,972
lines, `shcore::Value`), the `database/` layer and `utils/`, is engine
independent and stays.

| Responsibility | GraalVM today | V8 |
|---|---|---|
| Engine lifecycle, heap limits | isolate per service (`poly_create_isolate`, `IsolateArgs` min/max heap) | `v8::Isolate` per service, `ResourceConstraints`, near-heap-limit callback |
| Context pool, shared base context | `copy_global_context`, engine sharing (off when debugging) | `v8::Context` per pool entry, global object from a template; optional code cache |
| Execution thread per context, timeouts | `Jit-Run` thread, queue, `poly_context_interrupt` on timeout | same thread model, `Isolate::TerminateExecution()` (thread safe) |
| Promise results | `synch_return`/`synch_error` resolver function | `Promise::Then` plus explicit microtask checkpoint |
| ES modules from the content set | proxy file system (`IFile_system`, 311 lines, 2 wrappers), `Current_script` stack | `ScriptCompiler::CompileModule`, `ResolveModuleCallback` and dynamic-import callback reading through the same `IFile_system` |
| Native objects in JS (Session, Result, Row, Column, Date) | proxy object/array/function/iterator/map wrappers, `Object_bridge`, `Collectable` | `ObjectTemplate` with property handlers, `FunctionTemplate`, internal fields, weak handles |
| Value conversion | `type_conversion`, `types_polyglot`, `polyglot_utils` (~1,200 lines) | V8 handles: Number/BigInt/String/Array/Object/Date/ArrayBuffer |
| Errors | `polyglot_error.cc` (495 lines): guest stack traces, resource exhausted, interrupted | `TryCatch`, `Message`, `StackTrace`; OOM via heap-limit callback; `IsExecutionTerminating` |
| Memory accounting, idle teardown | `poly_perf_data` counters, `poly_system_gc` | `HeapStatistics`, `LowMemoryNotification` |
| Debugger | `inspect` option: GraalVM's own CDP server on the debug port | `v8_inspector` plus our WebSocket server on the debug port (new code) |
| Build | `bootstrap_jit_executor.cmake`: GraalVM, Maven, native image, patches | `bootstrap_v8.cmake`: prebuilt monolith per platform, SHA-256 pinned |
| Packaging | `libjitexecutor.so` bundled next to the plugin | V8 linked statically into the plugin; `snapshot_blob.bin`, `icudtl.dat` if i18n |

## Where V8 comes from

Building V8 from source needs depot_tools, gn and ninja and takes one to two
hours per platform. Prebuilt static monoliths are the practical route:

- **kassane/libv8** (v15.1.46, 2026-06-08): linux x64/arm64, macOS arm64,
  windows x64/arm64, each in `default`, `i18n` and `pointer-compression`
  variants, with SHA256SUMS. **No macOS x64.**
- **zyedidia/v8-build** (v14.0.365, 2026-01): linux x64/arm64, macOS arm64,
  windows x64/arm64. Also no macOS x64.
- vcpkg's `v8` port is 9.1.269.39 (2021): not usable.

So macOS x64 needs a build of our own (a GitHub macos-15-intel runner, cached
by version like the JIT library today) or is dropped. Either way the download
is pinned by version and checksum, as GraalVM is in
`cmake/bootstrap_jit_executor.cmake` now.

A prebuilt monolith must match our toolchain: V8's default build uses its own
clang and libc++ (`use_custom_libcxx=true`), which doesn't link against a
libstdc++ build on Rocky 9, and on Windows the CRT flavour (`/MD`) must match.
This is checked first, in the spike.

## Phases

### Phase V0: spike (1 week)

- Link the prebuilt V8 on macOS arm64 and Linux x64 (Rocky 9 container) into
  a throwaway plugin build; confirm the toolchain questions above and the
  Windows arm64 link with our MSVC.
- Run one content-set script end to end with a minimal engine: module load
  from `IFile_system`, `getSession().runSql()`, promise result, timeout.
- Attach VS Code once to a hand-written WebSocket loop to confirm the pause
  loop on the execution thread.
- Decide the variant: `i18n` (scripts keep `Intl` and locale-aware
  `toLocaleString`, as GraalJS has them via ICU4J; adds `icudtl.dat`, ~10 MB)
  or `default`.
- Exit: go/no-go with the toolchain answers and the chosen V8 source.

### Phase V1: engine core (2–3 weeks)

- `src/jit_executor/src/v8/`: isolate and context lifecycle, pool, the
  execution thread with queue, timeouts and termination, promise resolution,
  ES module loading and dynamic `import()` from the content set, error
  mapping with guest stack traces, `print`, the four global functions.
- Memory limits: `max_heap_size`, `maximum_ram_size`, `memory_units` on
  `HeapStatistics`.
- Exit: `scripting_base_tests` and `scripting_multi_service` pass on macOS.

### Phase V2: object bridge and types (2 weeks)

- Session, Result, Row, Column, Date on templates; value conversion both
  ways including BigInt, Date, binary and nested arrays/objects; weak
  handles for collectable natives.
- Exit: `scripting_type_bridging` passes; the MRS suite passes on Linux,
  macOS and Windows x64. Golden `.result` files that quote engine error
  messages are updated deliberately (GraalJS and V8 word them differently).

### Phase V3: debugger (1–2 weeks)

- `V8InspectorClient` and `Channel` implementation; one inspector session per
  debug context; `runMessageLoopOnPause` on the execution thread; no timeout
  while debugging (as today).
- WebSocket server on the debug port, separate from the daemon's HTTP server
  (GraalVM's inspector also opens its own port): `GET /json/version`,
  `GET /json/list` and the RFC 6455 upgrade. Hand-written (a few hundred
  lines) or `ixwebsocket` (BSD-3, in vcpkg). Decided in V0.
- Keep the debug-context semantics: `get_context(debug_port)`,
  `release_debug_context`, `stop_debug_context`, the `_debug` toggle.
- Exit: the shell plugins' `mrs_scripts` launch config attaches unchanged,
  breakpoints in `.ts` sources bind through the source maps, stepping and
  variables work, Chrome DevTools can attach too.

### Phase V4: build, CI, packaging (1–2 weeks)

- `cmake/bootstrap_v8.cmake` replaces `bootstrap_jit_executor.cmake`;
  `WITH_JIT_EXECUTOR` / `MRS_JIT_EXECUTOR_LIB` keep their meaning for the
  release workflow's cache.
- Release workflow: a native windows-arm64 leg (the ARM64 runner builds ARM64
  now) and a decision on macOS x64 (own V8 build, cached, or drop the leg).
  `verify_package.sh`: no `libjitexecutor`, the plugin loads, a script runs.
- Packaging: static link; `snapshot_blob.bin` and `icudtl.dat` next to the
  plugin; RPM/deb requires filters.
- LICENSE: remove the GraalVM, OpenJDK and GraalJS sections; add V8 (BSD-3)
  and its third-party notices (ICU, zlib and the others V8 bundles). **Legal
  reviews the result** (the written offer can stay; it's cheap and covers the
  MySQL-derived GPL code regardless).
- Exit: all packages built and verified; LICENSE cleared.

### Phase V5: cutover and cleanup (1 week)

- Remove `ext/polyglot`, the `polyglot_*` sources, `IsolateArgs`, the GraalVM
  download; README, PLAN.md, PROGRESS.md, PROJECT_CONTEXT.md.
- Tag the last GraalVM commit; keep it as the fallback until the first V8
  release has shipped and run for a cycle.
- Exit: first pre-release with V8; `restd --version` and the packages show no
  GraalVM.

**Total: about 8–11 weeks of one engineer**, plus legal's turnaround on the
LICENSE. V1 and V2 are the bulk; the debugger is the smallest part.

## Risks

| Risk | Mitigation |
|---|---|
| Prebuilt V8 comes from an individual's project | Pin version and SHA-256 as for GraalVM; mirror the archives we use; the fallback is our own CI build per platform, cached by version |
| Toolchain mismatch (libc++ vs libstdc++, CRT flavour) | Checked in V0 before anything else; own build with `use_custom_libcxx=false` if needed |
| No prebuilt macOS x64 | Own build on the Intel runner, or drop the package (GraalVM forces the same choice at its next upgrade) |
| Behaviour differences GraalJS → V8 (error texts, `Intl`, strictness) | The MRS suite's three scripting tests and the type-bridging test are the gate; golden files updated with intent, not blindly |
| Memory-limit semantics differ (GraalVM heap per isolate vs V8 resource constraints) | Keep the configuration surface; map to `ResourceConstraints` plus the heap-limit callback; document the new numbers |
| Debugger pause loop on a pooled execution thread | Debug contexts are dedicated already (no pool, no timeout); the loop runs only there |
| V8 API churn (a release every four weeks) | Pin; update twice a year as a planned task |
| Binary size (monolith ~30–40 MB, `icudtl.dat` ~10 MB) | Comparable to today's `libjitexecutor`; measure in V0 |

## Decisions needed before V0

1. Go ahead with the spike at all.
2. `i18n` variant (full `Intl`, matches GraalJS) or `default`.
3. V8 source: kassane/libv8 as is, or our own CI builds from the start.
4. macOS x64: own V8 build or drop the package.
5. WebSocket transport: hand-written or `ixwebsocket`.

## Decision log

- 2026-10-30: plan written; GraalVM confirmed to have no Windows ARM64 (none
  planned) and no macOS x64 after 25.0.0; the scripts use nothing
  GraalJS-specific; VS Code attaches over CDP in both cases.
