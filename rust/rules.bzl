load("@rules_cc//cc:toolchain_utils.bzl", "find_cpp_toolchain")
load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "CPP_LINK_EXECUTABLE_ACTION_NAME")

CrateInfo = provider(
    fields = [
        "name",
        "rlib",
        "deps",
        "type",
        "root",
        "srcs",
    ],
)

CrateDepInfo = provider(
    fields = [
        "trans_crates",
        "trans_libs",
    ],
)

def _get_cc_libs_for_static_executable(dep):
    libraries_to_link = dep[CcInfo].linking_context.libraries_to_link
    return depset([_get_cc_lib_preferred_artifact(lib) for lib in libraries_to_link.to_list()])

def _get_cc_lib_preferred_artifact(library_to_link):
    return (
        library_to_link.static_library or
        library_to_link.pic_static_library or
        library_to_link.interface_library or
        library_to_link.dynamic_library
    )

def _get_transitive_crates(deps):
    trans_crates = depset()
    trans_libs = depset()
    for dep in deps:
        if CrateInfo in dep:
            trans_crates = depset([dep[CrateInfo]], transitive = [trans_crates])
            trans_crates = depset(transitive = [trans_crates, dep[CrateDepInfo].trans_crates])
            trans_libs = depset(transitive = [trans_libs, dep[CrateDepInfo].trans_libs])
        elif CcInfo in dep:
            libs = _get_cc_libs_for_static_executable(dep)
            trans_libs = depset(transitive = [trans_libs, libs])
    return CrateDepInfo(
        trans_crates = trans_crates,
        trans_libs = trans_libs,
    )

def _get_crate_dirname(c):
    return c.dirname

def _get_lib_path(c):
    return c.path[:-4]

def _rustc(ctx, root, srcs, deps, output, crate_type):
    is_test = False
    if crate_type == "test":
        is_test = True
        crate_type = "bin"

    rustc = ctx.toolchains["@rules_rust//rust:toolchain_type"].rustcinfo.rustc
    lld = ctx.toolchains["@rules_rust//rust:toolchain_type"].rustcinfo.lld
    cc_toolchain = find_cpp_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        is_linking_dynamic_library = False,
    )
    link_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        variables = link_variables,
    )
    link_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        variables = link_variables,
    )

    env = {}
    env.update(link_env)

    args = ctx.actions.args()
    args.add(root.path)
    args.add("--crate-name", ctx.label.name)
    args.add("--crate-type", crate_type)
    args.add("--edition=2018")
    if is_test:
        args.add("--test")
    args.add("-o", output.path)
    args.add("-C")
    args.add("linker=%s" % lld.path)
    args.add("-C")
    args.add("linker-flavor=lld-link")
    args.add_joined("--codegen", link_args, join_with = " ", format_joined = "link-args=%s")

    trans_deps = _get_transitive_crates(deps)
    trans_deps_crates = trans_deps.trans_crates
    trans_deps_libs = trans_deps.trans_libs
    crates_inputs = []
    inputs_deps = depset([root] + srcs)
    for dep in trans_deps_crates.to_list():
        if dep.type == "lib":
            args.add("--extern")
            args.add("%s=%s" % (dep.name, dep.rlib.path))
            inputs_deps = depset([dep.rlib] + dep.srcs, transitive = [inputs_deps])
            crates_inputs += [dep.rlib]
    inputs_deps = depset(transitive = [inputs_deps, trans_deps_libs])

    args.add_all(
        crates_inputs,
        map_each = _get_crate_dirname,
        uniquify = True,
        format_each = "-Ldependency=%s")

    if crate_type == "bin":
        args.add_all(
            trans_deps_libs.to_list(),
            map_each = _get_lib_path,
            uniquify = True,
            format_each = "-lstatic=%s")

    ctx.actions.run(
        outputs = [output],
        inputs = inputs_deps,
        executable = rustc,
        arguments = [args],
        tools = [rustc, lld],
        env = env,
    )

def _rust_binary_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".exe")
    _rustc(ctx, ctx.file.root, ctx.files.srcs, ctx.attr.deps, output, "bin")
    return [
        DefaultInfo(
            executable = output,
        ),
        CrateInfo(
            name = ctx.label.name,
            rlib = output,
            deps = ctx.attr.deps,
            type = "bin",
            root = ctx.file.root,
            srcs = ctx.files.srcs,
        ),
    ]

def _rust_library_impl(ctx):
    output = ctx.actions.declare_file("lib" + ctx.label.name + ".rlib")
    _rustc(ctx, ctx.file.root, ctx.files.srcs, ctx.attr.deps, output, "lib")
    return [
        DefaultInfo(files = depset([output])),
        CrateInfo(
            name = ctx.label.name,
            rlib = output,
            deps = ctx.attr.deps,
            type = "lib",
            root = ctx.file.root,
            srcs = ctx.files.srcs,
        ),
        _get_transitive_crates(ctx.attr.deps),
    ]

def _rust_test_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".exe")
    crate_info = ctx.attr.crate[CrateInfo]
    _rustc(ctx, crate_info.root, crate_info.srcs, crate_info.deps, output, "test")
    return [
        DefaultInfo(
            executable = output,
        ),
    ]

rust_binary = rule(
    implementation = _rust_binary_impl,
    attrs = {
        "root": attr.label(mandatory = True, allow_single_file=True),
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "deps": attr.label_list(
            providers = [
                [CrateInfo, CrateDepInfo],
                [CcInfo],
            ],
        ),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    toolchains = [
        "@rules_rust//rust:toolchain_type",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
    executable = True,
)

rust_library = rule(
    implementation = _rust_library_impl,
    attrs = {
        "root": attr.label(mandatory = True, allow_single_file=True),
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "deps": attr.label_list(
            providers = [
                [CrateInfo, CrateDepInfo],
                [CcInfo],
            ],
        ),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    toolchains = [
        "@rules_rust//rust:toolchain_type",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
)

rust_test = rule(
    implementation = _rust_test_impl,
    attrs = {
        "crate": attr.label(mandatory = True, providers = [CrateInfo]),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    toolchains = [
        "@rules_rust//rust:toolchain_type",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
    test = True,
)
