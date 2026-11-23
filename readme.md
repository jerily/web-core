# web-core

Tcl packages describe their HTTP routes in an installed `api.json`. The shared reader resolves those declarations into native tpathexp routes. The public schema describes both installed packages and application route compositions. [ttrek-web-api/1 schema](schemas/api-v1.json)

## Package discovery

Install the manifest alongside the package index. Give the metadata package the same version as its parent and require that exact metadata version from the parent. Add a metadata entry to that index so a host can find the manifest and assets before loading a handler or opening a database.

```tcl
package ifneeded web-forum::manifest 1.0.0 [list apply {{dir} {
    package require web-core
    ::web::core::register web-forum $dir
    package provide web-forum::manifest 1.0.0
}} $dir]
```

`::web::core::directory package` returns the registered package directory. Use `[file join [::web::core::directory web-core] schemas api-v1.json]` to locate the installed schema. `::web::core::manifest package` reads and caches its validated package manifest in the interpreter. Pass that value to the route planner. Configuration and bound handlers belong to each individual mount.

## Install routes

```tcl
package require web-core
set manifest [::web::core::manifest web-forum]
set plan [::web::core::route_plan $manifest /discuss $config]
::web::core::install $router $plan
```

The caller supplies an existing router and a prepared package configuration. The optional arguments to `route_plan` are the settings dictionary, policy dictionary, and command adapter, in that order. Boolean inputs in `when.anyTrue` select routes at mount time. The package handler or hosting application enforces request-time access. The returned dictionary contains all candidate `paths` for collision checks, ordered router `middleware`, and enabled `routes`. A route carries `id`, `methods`, `path`, `handler`, and native router `options`. A root mount registers identical bare and trailing-slash index aliases once.

Each command prefix begins with a fully qualified Tcl procedure. A string argument is literal. The object `{"bind":"config"}` inserts the supplied configuration as one Tcl argument. The prefix `["::web::blog::dispatch", {"bind":"config"}, "view"]` becomes `[list ::web::blog::dispatch $config view]`. At dispatch, the router appends the request, context, and path parameters. Enter hooks receive context and request. Leave hooks receive context, request, and response.

A host that initializes a mount lazily can supply a command adapter. The planner calls `{*}$adapter $command $indexes` for each enabled handler and hook. The adapter returns a Tcl command prefix. The zero-based indexes identify bound arguments even when a literal argument has the same value. `install router plan ?handlerWrapper?` optionally wraps handlers as `[list {*}$handlerWrapper $handler]`, preserving each original prefix as one argument.

`::web::core::options defaults ?key value ...?` merges explicit named options into a defaults dictionary. Unknown keys and unpaired values raise an error.

## Build and test

Install tjson 1.0.30 and tpathexp 1.2.0 for the same Tcl ABI as the runtime. Configure with CMake and run CTest before installing.

```sh
cmake -S . -B build
ctest --test-dir build --output-on-failure
cmake --install build --prefix /path/to/prefix
```
