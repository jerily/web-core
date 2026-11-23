package require Tcl 8.6 9
package require tjson 1.0.30
package require tpathexp 1.2.0

namespace eval ::web::core {
    variable directories [dict create]
    variable manifests [dict create]
    variable methods {GET HEAD POST PUT DELETE OPTIONS PATCH TRACE CONNECT}
}

# Merge named options into their declared defaults.
proc ::web::core::options {defaults args} {
    if {[llength $args] % 2} {error "options must be name/value pairs"}
    foreach {key value} $args {
        if {![dict exists $defaults $key]} {error "unknown option: $key"}
        dict set defaults $key $value
    }
    return $defaults
}

# Register an installed package's asset and manifest directory.
proc ::web::core::register {package directory} {
    variable directories
    variable manifests
    dict set directories $package [file normalize $directory]
    dict unset manifests $package
}

# Locate package metadata without loading its handlers or stores.
proc ::web::core::directory {package} {
    variable directories
    if {![dict exists $directories $package]} {
        set loaded [package provide $package]
        if {$loaded eq {}} {
            package require ${package}::manifest
        } else {
            package require -exact ${package}::manifest $loaded
        }
    }
    return [dict get $directories $package]
}

# Check an object's required and optional fields with their JSON types.
proc ::web::core::fields {node required {optional {}}} {
    lassign $node type object
    if {$type ne "M"} {error "expected a manifest object"}
    foreach name [dict keys $required] {
        if {![dict exists $object $name]} {error "missing manifest field: $name"}
    }
    set allowed [dict merge $required $optional]
    dict for {name field} $object {
        if {![dict exists $allowed $name] || [lindex $field 0] ne [dict get $allowed $name]} {
            error "invalid manifest field: $name"
        }
    }
    return $object
}

# Read an array of distinct JSON strings.
proc ::web::core::strings {node} {
    set result {}
    foreach entry [lindex $node 1] {
        lassign $entry type value
        if {$type ne "S" || $value in $result} {error "expected distinct strings"}
        lappend result $value
    }
    if {![llength $result]} {error "expected a nonempty list"}
    return $result
}

# Decode command words and record the exact positions of configuration bindings.
proc ::web::core::command {node} {
    set entries [lindex $node 1]
    lassign [lindex $entries 0] type name
    if {$type ne "S" || ![regexp {^(::[a-zA-Z_][a-zA-Z0-9_-]*)+$} $name]} {
        error "expected a fully qualified Tcl procedure"
    }
    set words [list $name]
    set bindings {}
    foreach entry [lrange $entries 1 end] {
        lassign $entry type value
        switch -- $type {
            S {lappend words $value}
            M {
                if {[dict size $value] != 1 || ![dict exists $value bind] || [dict get $value bind] ne {S config}} {
                    error "expected a config binding"
                }
                lappend bindings [llength $words]
                lappend words {}
            }
            default {error "expected a literal command word or a config binding"}
        }
    }
    return [list $words $bindings]
}

# Compile the optional enter and leave prefixes of one layer.
proc ::web::core::hooks {fields} {
    set result {}
    foreach hook {enter_proc leave_proc} {
        if {[dict exists $fields $hook]} {dict set result -$hook [command [dict get $fields $hook]]}
    }
    return $result
}

# Read package metadata and validate each route once per interpreter.
proc ::web::core::manifest {package} {
    variable manifests
    if {[dict exists $manifests $package]} {return [dict get $manifests $package]}
    set file [file join [directory $package] api.json]
    set channel [open $file r]
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        set source [read $channel 1048577]
    } finally {close $channel}
    set tree [::tjson::json_to_typed -maxbytes 1048576 -maxdepth 32 $source]
    set result [parse $package $tree]
    dict set manifests $package $result
    return $result
}

# Validate documented public commands and host-supplied callbacks.
proc ::web::core::validate_docs {kind node} {
    dict for {name declaration} [lindex $node 1] {
        if {$kind eq "commands"} {command [list L [list [list S $name]]]}
        set spec [fields $declaration {arguments L returns S summary S}]
        foreach key {returns summary} {
            if {[lindex [dict get $spec $key] 1] eq {}} {error "expected $key in documentation for $name"}
        }
        foreach argument [lindex [dict get $spec arguments] 1] {
            if {[lindex $argument 0] ne "S" || [lindex $argument 1] eq {}} {
                error "expected an argument name in documentation for $name"
            }
        }
    }
}

# Validate package mount settings and normalize the manifest for planning.
proc ::web::core::parse {package tree} {
    set spec [fields $tree {format S package S summary S mount M inputs M router M routerMiddleware L routes L} \
        {commands M callbacks M $schema S}]
    set manifest [::tjson::typed_to_simple $tree]
    if {[dict get $manifest format] ne "ttrek-web-api/1" || [dict get $manifest package] ne $package ||
        ![regexp {^[a-zA-Z0-9_-]+(::[a-zA-Z0-9_-]+)*$} $package]} {
        error "expected a ttrek-web-api/1 manifest for $package"
    }
    set mount [fields [dict get $spec mount] {command S prefix M docs S}]
    command [list L [list [dict get $mount command]]]
    if {[dict get $manifest summary] eq {} || [dict get $manifest mount docs] eq {}} {
        error "expected a package summary and mounting documentation"
    }
    foreach field {commands callbacks} {
        if {[dict exists $spec $field]} {validate_docs $field [dict get $spec $field]}
    }
    fields [dict get $mount prefix] {option S default S allowRoot BOOL} {key S}
    set prefix [dict get $manifest mount prefix]
    if {![regexp {^-[a-zA-Z_][a-zA-Z0-9_-]*$} [dict get $prefix option]]} {error "invalid mount prefix option"}
    if {[dict exists $prefix key] && [dict get $prefix key] eq {}} {error "expected a mount prefix key"}
    set default [dict get $prefix default]
    if {$default ni {{} /} && [string trimright $default /] ne $default} {error "invalid default mount prefix"}
    normalize_prefix $default [dict get $prefix allowRoot]
    fields [dict get $spec router] {engine S strict BOOL}
    if {[dict get $manifest router engine] ne "tpathexp"} {error "unsupported route engine"}
    dict for {flag input} [lindex [dict get $spec inputs] 1] {
        fields $input {type S default BOOL summary S}
        if {![regexp {^(settings|policy)\.[A-Za-z_][A-Za-z_0-9]*$} $flag] ||
            [dict get $manifest inputs $flag type] ne "boolean" || [dict get $manifest inputs $flag summary] eq {}} {
            error "invalid route input: $flag"
        }
    }
    set middleware {}
    foreach node [lindex [dict get $spec routerMiddleware] 1] {
        set layer [hooks [fields $node {} {enter_proc L leave_proc L}]]
        if {![dict size $layer]} {error "empty router middleware layer"}
        lappend middleware $layer
    }
    dict set manifest routerMiddleware $middleware
    set routes {}
    set ids {}
    set registered {}
    foreach node [lindex [dict get $spec routes] 1] {
        set route [parse_route $node $manifest]
        set id [dict get $route id]
        set path [dict get $route path]
        if {[dict exists $ids $id]} {error "duplicate route ID: $id"}
        dict set ids $id 1
        foreach method [dict get $route methods] {
            if {[dict exists $registered $path $method] || [dict exists $registered $path ANY] ||
                ($method eq "ANY" && [dict exists $registered $path])} {error "duplicate route: $method $path"}
            dict set registered $path $method 1
        }
        lappend routes $route
    }
    dict set manifest routes $routes
    return $manifest
}

# Check one route's declared methods, path, bindings, and mount conditions.
proc ::web::core::parse_route {node manifest} {
    variable methods
    set spec [fields $node {id S summary S methods L path S handler L} \
        {when M enter_proc L leave_proc L access M operations M}]
    set route [::tjson::typed_to_simple $node]
    set id [dict get $route id]
    if {[dict get $route summary] eq {}} {error "expected a summary for route $id"}
    if {![regexp {^[a-z][a-z0-9._-]*$} $id]} {error "invalid route ID: $id"}
    set verbs [strings [dict get $spec methods]]
    foreach verb $verbs {
        if {$verb ni $methods && $verb ne "ANY"} {error "invalid HTTP method: $verb"}
    }
    if {"ANY" in $verbs && [llength $verbs] > 1} {error "ANY must be used alone"}
    set suffix [dict get $route path]
    if {$suffix ne {} && [string index $suffix 0] ne "/"} {error "invalid route path: $suffix"}
    # Check native path syntax before installing any part of a manifest.
    set matcher [::tpathexp::compile -strict [dict get $manifest router strict] -- /mount$suffix]
    $matcher destroy
    if {[dict exists $spec when]} {
        set when [fields [dict get $spec when] {anyTrue L}]
        foreach flag [strings [dict get $when anyTrue]] {
            if {![dict exists $manifest inputs $flag]} {error "unknown condition on $id: $flag"}
        }
    }
    if {[dict exists $spec access]} {
        set access [fields [dict get $spec access] {} {signedIn BOOL permission S}]
        if {[dict size $access] != 1} {error "invalid access rule for $id"}
        if {[dict exists $access signedIn] && ![dict get $route access signedIn]} {error "signedIn must be true"}
        if {[dict exists $access permission] && ![regexp {^[a-z][a-z0-9_.:-]{0,127}$} [dict get $route access permission]]} {
            error "invalid permission for $id"
        }
    }
    if {[dict exists $spec operations]} {
        dict for {method reference} [lindex [dict get $spec operations] 1] {
            lassign $reference type path
            if {$method ni $verbs || $type ne "S" ||
                ![regexp {^([A-Za-z0-9_-][A-Za-z0-9_.-]*/)*[A-Za-z0-9_-][A-Za-z0-9_.-]*\.json(#/.*)?$} $path]} {
                error "invalid operation for $id: $method"
            }
        }
    }
    dict set route handler [command [dict get $spec handler]]
    foreach {hook decoded} [hooks $spec] {dict set route [string range $hook 1 end] $decoded}
    return $route
}

# Bind a mount as a single word and optionally adapt the completed prefix.
proc ::web::core::bind {command config adapter} {
    lassign $command words bindings
    foreach index $bindings {lset words $index $config}
    if {[llength $adapter]} {return [{*}$adapter $words $bindings]}
    return $words
}

# Build native hook options from the route or router layer.
proc ::web::core::bind_hooks {layer config adapter} {
    set result {}
    dict for {hook command} $layer {dict set result $hook [bind $command $config $adapter]}
    return $result
}

# Resolve all mount conditions with their defaults and validate supplied booleans.
proc ::web::core::flags {inputs settings policy} {
    set groups [dict create settings $settings policy $policy]
    set flags {}
    dict for {flag input} $inputs {
        lassign [split $flag .] group key
        set value [dict get $input default]
        if {[dict exists $groups $group $key]} {set value [dict get $groups $group $key]}
        if {![string is boolean -strict $value]} {error "$key must be a boolean"}
        dict set flags $flag $value
    }
    return $flags
}

# Normalize a literal mount prefix for joining relative route paths.
proc ::web::core::normalize_prefix {prefix allowRoot} {
    set prefix [string trimright $prefix /]
    if {$prefix eq {} && !$allowRoot} {error "mount prefix must be a non-root local path"}
    if {![regexp {^(/[A-Za-z0-9_-]+)*$} $prefix]} {error "mount prefix must be a literal local path"}
    return $prefix
}

# Resolve enabled routes, reserved paths and middleware for one mount.
proc ::web::core::route_plan {manifest prefix config {settings {}} {policy {}} {commandAdapter {}}} {
    set prefix [normalize_prefix $prefix [dict get $manifest mount prefix allowRoot]]
    set inputs [flags [dict get $manifest inputs] $settings $policy]
    set layers {}
    foreach layer [dict get $manifest routerMiddleware] {
        lappend layers [bind_hooks $layer $config $commandAdapter]
    }
    set routes {}
    set paths {}
    set rootMethods {}
    foreach route [dict get $manifest routes] {
        set suffix [dict get $route path]
        set path $prefix$suffix
        if {$path eq {}} {set path /}
        dict set paths $path 1
        # At the root, the bare index and its trailing-slash alias are the same URL.
        if {$prefix eq {} && $path eq "/"} {
            set signature {}
            foreach key {handler enter_proc leave_proc when access operations} {
                if {[dict exists $route $key]} {dict set signature $key [dict get $route $key]}
            }
            set verbs [lsort [dict get $route methods]]
            dict set signature methods $verbs
            if {($verbs eq "ANY" && [dict size $rootMethods] && ![dict exists $rootMethods ANY]) ||
                ($verbs ne "ANY" && [dict exists $rootMethods ANY])} {error "conflicting root routes for ANY /"}
            set alias false
            foreach method $verbs {
                if {[dict exists $rootMethods $method]} {
                    if {[dict get $rootMethods $method] ne $signature} {error "conflicting root routes for $method /"}
                    set alias true
                }
                dict set rootMethods $method $signature
            }
            if {$alias} continue
        }
        if {[dict exists $route when]} {
            set enabled false
            foreach flag [dict get $route when anyTrue] {
                if {[dict get $inputs $flag]} {set enabled true; break}
            }
            if {!$enabled} continue
        }
        set options [dict create -strict [dict get $manifest router strict]]
        foreach hook {enter_proc leave_proc} {
            if {[dict exists $route $hook]} {
                dict set options -$hook [bind [dict get $route $hook] $config $commandAdapter]
            }
        }
        lappend routes [dict create id [dict get $route id] methods [dict get $route methods] path $path \
            handler [bind [dict get $route handler] $config $commandAdapter] options $options]
    }
    return [dict create paths [dict keys $paths] middleware $layers routes $routes]
}

# Check reserved paths before applying a plan to the supplied native router.
proc ::web::core::install {router plan {handlerWrapper {}}} {
    foreach path [dict get $plan paths] {
        if {[dict get [$router match GET $path] statusCode] != 404} {error "route already mounted: $path"}
    }
    foreach layer [dict get $plan middleware] {$router add_middleware {*}$layer}
    foreach route [dict get $plan routes] {
        set handler [dict get $route handler]
        if {[llength $handlerWrapper]} {set handler [list {*}$handlerWrapper $handler]}
        $router add [dict get $route methods] [dict get $route path] $handler {*}[dict get $route options]
    }
}
::web::core::register web-core [file dirname [file dirname [file normalize [info script]]]]
package provide web-core 0.1.0
