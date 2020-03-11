RustcInfo = provider(
    fields = [
        "rustc",
        "lld",
    ],
)

def _rust_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        rustcinfo = RustcInfo(
            rustc = ctx.executable.rustc,
            lld = ctx.executable.lld,
        ),
    )
    return [toolchain_info]

rust_toolchain = rule(
    implementation = _rust_toolchain_impl,
    attrs = {
        "rustc": attr.label(mandatory=True, allow_single_file=True, executable=True, cfg="host"),
        "lld": attr.label(mandatory=True, allow_single_file=True, executable=True, cfg="host"),
    },
)

def _find_url(lines, pkg):
    found_pkg = False
    for l in lines:
        if l == pkg:
            found_pkg = True
        elif found_pkg and l.startswith("url = "):
            return l[7:-1]
    fail("Couldn't find package %s" % pkg)

def _download(ctx):
    triple = "x86_64-pc-windows-msvc"
    version = "1.41.1"

    url = "https://static.rust-lang.org/dist/channel-rust-%s.toml" % version
    rustc_name = "[pkg.rustc.target.%s]" % triple
    ruststd_name = "[pkg.rust-std.target.%s]" % triple

    ctx.download(url, output="manifest.toml")
    manifest_lines = ctx.read("manifest.toml").splitlines()

    rustc_url = _find_url(manifest_lines, rustc_name)
    ruststd_url = _find_url(manifest_lines, ruststd_name)

    rustc_prefix = "rustc-%s-%s/rustc" % (version, triple)
    ruststd_prefix = "rust-std-%s-%s/rust-std-%s" % (version, triple, triple)

    ctx.download_and_extract(rustc_url, stripPrefix=rustc_prefix)
    ctx.download_and_extract(ruststd_url, stripPrefix=ruststd_prefix)

def _rust_repo_impl(ctx):
    _download(ctx)
    ctx.file("BUILD", content = """
load("@rules_rust//rust:rust_repo.bzl", "rust_toolchain")

exports_files(
    glob(["**/*"]),
    visibility = ["//visibility:public"],
)

rust_toolchain(
    name = "rustc",
    rustc = "bin/rustc.exe",
    lld = "lib/rustlib/x86_64-pc-windows-msvc/bin/rust-lld.exe",
)

toolchain(
    name = "rustc_toolchain",
    exec_compatible_with = [
        "@platforms//os:windows",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@platforms//os:windows",
        "@platforms//cpu:x86_64",
    ],
    toolchain = ":rustc",
    toolchain_type = "@rules_rust//rust:toolchain_type",
    visibility = ["//visibility:public"],
)
""")

rust_repo_inner = repository_rule(
    implementation = _rust_repo_impl
)

def rust_repo(name):
    rust_repo_inner(name = name)
    native.register_toolchains("@%s//:rustc_toolchain" % name)
