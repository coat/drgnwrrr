const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // `-Dtarget=wasm32-freestanding` means the web game: `install` builds it
    // and `run` serves it. The CLI, tests and romcheck then build for the host.
    const web_target = target.result.cpu.arch.isWasm();
    const native = if (web_target) b.graph.host else target;
    const strip = b.option(bool, "strip", "Strip the CLI and native game. Default on for ReleaseFast and ReleaseSmall") orelse
        (optimize == .fast or optimize == .small);

    // The maps and NPC tables come from the ROM at build time: romextract
    // decodes them with the ROM-checked dw.Maps.fromBank0 and writes Zig source.
    const rom = b.option([]const u8, "rom", "Dragon Warrior (U) ROM to build the maps from (default: dragon_warrior.nes)") orelse
        "dragon_warrior.nes";
    const host_dw = b.createModule(.{
        .root_source_file = b.path("tools/romcheck/reference.zig"),
        .target = b.graph.host,
    });
    const romextract = b.addExecutable(.{
        .name = "romextract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/romextract/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "dw", .module = host_dw }},
        }),
    });
    const romextract_cmd = b.addRunArtifact(romextract);
    romextract_cmd.addFileArg(if (std.fs.path.isAbsolute(rom)) .{ .cwd_relative = rom } else b.path(rom));
    const romdata = romextract_cmd.addOutputFileArg("romdata.zig");

    const mod = engine(b, native, romdata, true);

    // The sprite atlas: tools/atlas packs the sprites src/gfx/looks.zig draws
    // (from the Kenney sheets in assets/) and the Anvil font into atlas.png,
    // and writes atlas.zig and atlas.js saying where they landed.
    const atlas_tool = b.addExecutable(.{
        .name = "atlas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/atlas/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "looks", .module = b.createModule(.{
                .root_source_file = b.path("src/gfx/looks.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "dw", .module = host_dw }},
            }) }},
        }),
    });
    const atlas_cmd = b.addRunArtifact(atlas_tool);
    atlas_cmd.addFileArg(b.path("assets/1bit.png"));
    atlas_cmd.addFileArg(b.path("assets/prompts.png"));
    atlas_cmd.addFileArg(b.path("assets/anvil.bin"));
    const atlas = atlas_cmd.addOutputDirectoryArg("atlas");

    // `-Dandroid` means the native game as an APK, and nothing else: it needs
    // the Android SDK (ANDROID_HOME, as the flake's devShell sets it).
    if (b.option(bool, "android", "Build the native game as zig-out/bin/drgnwrrr.apk; `run` installs and starts it over adb") orelse false) {
        addAndroid(b, optimize, romdata, atlas);
        return;
    }

    // The CLI game. Only this executable links libc, for isocline (line
    // editing: history, ctrl+r, Tab completion). The engine module doesn't.
    const isocline = b.dependency("isocline", .{});
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = native,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "drgnwrrr", .module = mod },
        },
    });
    cli_mod.addCSourceFile(.{ .file = isocline.path("src/isocline.c"), .flags = &.{"-std=c99"} });
    cli_mod.addIncludePath(isocline.path("include"));

    const exe = b.addExecutable(.{
        .name = "drgnwrrr-cli",
        .root_module = cli_mod,
    });
    const install_cli = b.addInstallArtifact(exe, .{});

    // The web game: the engine as a freestanding wasm module plus web/, in
    // zig-out/web. Debug builds are too slow for the route planner's battle
    // sims, so it's ReleaseSmall unless you ask for another release mode.
    const wasm = b.addExecutable(.{
        .name = "drgnwrrr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = if (optimize == .debug) .small else optimize,
            .imports = &.{.{ .name = "drgnwrrr", .module = engine(b, b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }), romdata, false) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const web_step = b.step("web", "Build the web game into zig-out/web");
    web_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("web"), .install_dir = .prefix, .install_subdir = "web" }).step);
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    web_step.dependOn(&b.addInstallFileWithDir(atlas.path(b, "atlas.js"), .{ .custom = "web" }, "atlas.js").step);
    for ([_][]const u8{ "atlas.png", "favicon-16.png", "favicon-32.png", "icon-256.png" }) |name|
        web_step.dependOn(&b.addInstallFileWithDir(atlas.path(b, name), .{ .custom = "web/assets" }, name).step);
    for ([_][]const u8{ "LICENSE-kenney.txt", "LICENSE-kenney-input-prompts.txt" }) |name|
        web_step.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("assets/{s}", .{name})), .{ .custom = "web/assets" }, name).step);

    // The native game: SDL3 for the window, input and drawing, Clay for the
    // panel's layout. Like the CLI, it links libc; the engine still doesn't.
    const link_sdl = b.option(
        bool,
        "link_sdl",
        "Link the system's SDL3 instead of building it from source. Default true on Linux",
    ) orelse (native.result.os.tag == .linux and !native.result.abi.isAndroid());
    const sdl_step = b.step("sdl", "Build the native game (drgnwrrr) into zig-out/bin");
    const run_sdl_step = b.step("run-sdl", "Run the native game");
    if (addSdlGame(b, native, optimize, link_sdl, mod, atlas)) |sdl_exe| {
        sdl_exe.root_module.strip = strip;
        const install_sdl = b.addInstallArtifact(sdl_exe, .{});
        sdl_step.dependOn(&install_sdl.step);
        const run_sdl = b.addRunArtifact(sdl_exe);
        run_sdl.step.dependOn(&install_sdl.step);
        run_sdl.addPassthruArgs();
        run_sdl_step.dependOn(&run_sdl.step);
    }
    addPortmaster(b, optimize, romdata, atlas);

    const serve = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve/main.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const serve_cmd = b.addRunArtifact(serve);
    serve_cmd.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
    serve_cmd.addPassthruArgs(); // a port
    serve_cmd.step.dependOn(web_step);
    const serve_step = b.step("serve", "Build the web game and serve it on http://localhost:8080 (-- PORT for another)");
    serve_step.dependOn(&serve_cmd.step);

    const run_step = b.step("run", if (web_target) "Serve the web game" else "Run the CLI game (drgnwrrr-cli)");
    if (web_target) {
        b.getInstallStep().dependOn(web_step);
        run_step.dependOn(&serve_cmd.step);
    } else {
        b.getInstallStep().dependOn(&install_cli.step);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        run_step.dependOn(&run_cmd.step);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const reference_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/romcheck/reference.zig"),
            .target = native,
            .optimize = optimize,
        }),
    });

    const run_reference_tests = b.addRunArtifact(reference_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_reference_tests.step);

    // Always ReleaseFast: the full run emulates billions of 6502 instructions.
    const romcheck_exe = b.addExecutable(.{
        .name = "romcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/romcheck/main.zig"),
            .target = native,
            .optimize = .ReleaseFast,
        }),
    });

    const romcheck_cmd = b.addRunArtifact(romcheck_exe);
    romcheck_cmd.setCwd(b.path("."));
    romcheck_cmd.addArg(rom);
    romcheck_cmd.addPassthruArgs();

    const romcheck_step = b.step("romcheck", "Check tools/romcheck/reference.zig against the ROM (-- --full for exhaustive)");
    romcheck_step.dependOn(&romcheck_cmd.step);
}

/// The engine module (src/root.zig) for `target`, importing the ROM-checked
/// ports as `dw` (so `zig build romcheck` vouches for the code the game
/// actually runs) and the generated ROM data as `romdata`. `public` exposes
/// it to packages that depend on this one.
fn engine(b: *std.Build, target: std.Build.ResolvedTarget, romdata: std.Build.LazyPath, public: bool) *std.Build.Module {
    const dw = b.createModule(.{
        .root_source_file = b.path("tools/romcheck/reference.zig"),
        .target = target,
    });
    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "dw", .module = dw }},
    };
    const mod = if (public) b.addModule("drgnwrrr", options) else b.createModule(options);
    mod.addAnonymousImport("romdata", .{
        .root_source_file = romdata,
        .imports = &.{.{ .name = "dw", .module = dw }},
    });
    return mod;
}

/// The SDL3 game, or null while its lazy dependencies are being fetched.
fn addSdlGame(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    link_sdl: bool,
    engine_mod: *std.Build.Module,
    atlas: std.Build.LazyPath,
) ?*std.Build.Step.Compile {
    const mod = sdlModule(b, target, optimize, link_sdl, engine_mod, atlas) orelse return null;
    const exe = b.addExecutable(.{ .name = "drgnwrrr", .root_module = mod });
    // A windowed game, so no console window opens behind it. Debug builds
    // keep the console for std.debug.print.
    if (target.result.os.tag == .windows) exe.subsystem = if (optimize == .debug) .console else .windows;
    return exe;
}

/// The SDL3 game's root module (src/sdl/main.zig), or null while its lazy
/// dependencies are being fetched.
fn sdlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    link_sdl: bool,
    engine_mod: *std.Build.Module,
    atlas: std.Build.LazyPath,
) ?*std.Build.Module {
    const clay = b.lazyDependency("clay", .{}) orelse return null;
    const sdl = if (link_sdl) null else b.lazyDependency("sdl", .{ .target = target, .optimize = optimize }) orelse return null;

    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#define SDL_DISABLE_OLD_NAMES
            \\#include <SDL3/SDL.h>
            \\#define SDL_MAIN_HANDLED
            \\#include <SDL3/SDL_main.h>
            \\#include <clay.h>
        ),
        .target = target,
        .optimize = optimize,
        .link_system_libs = if (link_sdl) &.{.{ .name = "SDL3" }} else &.{},
    });
    translator.addIncludePath(clay.path(""));
    if (target.result.abi.isAndroid()) {
        // The NDK's headers use clang extensions translate-c doesn't take.
        translator.defineCMacro("_Nullable", "");
        translator.defineCMacro("_Nonnull", "");
        translator.defineCMacro("_FORTIFY_SOURCE", "0");
        translator.defineCMacro("__ANDROID_API__", b.fmt("{d}", .{target.result.os.version_range.linux.android}));
    }

    const mod = b.createModule(.{
        .root_source_file = b.path("src/sdl/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "drgnwrrr", .module = engine_mod },
            .{ .name = "c", .module = translator.mod },
            .{ .name = "atlas", .module = b.createModule(.{ .root_source_file = atlas.path(b, "atlas.zig") }) },
            .{ .name = "looks", .module = b.createModule(.{
                .root_source_file = b.path("src/gfx/looks.zig"),
                .imports = &.{.{ .name = "dw", .module = engine_mod.import_table.get("dw").? }},
            }) },
        },
    });
    mod.addIncludePath(clay.path(""));
    // Function and data sections, so the linker drops the parts of Clay we
    // never call.
    mod.addCSourceFile(.{ .file = b.path("src/sdl/clay.c"), .flags = &.{ "-std=c99", "-ffunction-sections", "-fdata-sections" } });
    // Nothing unwinds the stack (see std_options in main.zig). Except on
    // Windows: the flag reaches the mingw libc build, and winpthreads' SEH
    // handlers don't assemble without unwind tables.
    if (target.result.os.tag != .windows) mod.unwind_tables = .none;
    if (sdl) |dep| {
        mod.linkLibrary(dep.artifact("SDL3"));
        translator.linkLibrary(dep.artifact("SDL3"));
    } else mod.linkSystemLibrary("SDL3", .{});

    return mod;
}

/// android/AndroidManifest.xml's package. Changing it makes Android treat
/// the build as a different app.
const android_package = "com.sadbeast.drgnwrrr";

/// The Android app, zig-out/bin/drgnwrrr.apk: SDL's Java glue starting the
/// native game, built as libmain.so, with SDL3 built in. `run` installs and
/// starts it on the device adb sees.
fn addAndroid(b: *std.Build, optimize: std.builtin.Optimize, romdata: std.Build.LazyPath, atlas: std.Build.LazyPath) void {
    // Declared before the early returns: on the first run the lazy android
    // package isn't fetched yet, and an undeclared -D option fails the build
    // before Zig gets to fetch it.
    const keystore = b.option(
        []const u8,
        "android_keystore",
        "Sign the APK with this keystore, its password read from $ANDROID_KEYSTORE_PASSWORD. Default: a throwaway debug key",
    );
    const every_abi = b.option(
        bool,
        "android_abis",
        "Put every Android ABI in the APK (x86_64, armeabi-v7a, x86) instead of arm64-v8a alone",
    ) orelse false;

    if (b.graph.environ_map.get("ANDROID_HOME") == null) {
        b.getInstallStep().dependOn(&b.addFail("ANDROID_HOME is not set: run in the flake's devShell (nix develop)").step);
        return;
    }
    const android = b.lazyImport(@This(), "android") orelse return;
    const sdk = android.Sdk.create(b, .{ .cmdline_version = "20.0" });
    const apk = sdk.createApk(.{
        .name = "drgnwrrr",
        .api_level = .android15,
        .build_tools_version = "36.1.0",
        .ndk_version = "29.0.14206865",
    });
    if (keystore) |path| {
        // Exits instead of adding a fail step, which would leave the steps
        // below undeclared and hide this error behind "no step named".
        const password = b.graph.environ_map.get("ANDROID_KEYSTORE_PASSWORD") orelse {
            std.log.err("-Dandroid_keystore needs ANDROID_KEYSTORE_PASSWORD set", .{});
            std.process.exit(1);
        };
        apk.setKeyStore(.{ .file = .{ .cwd_relative = path }, .password = password });
    } else {
        // A throwaway debug key: enough for `adb install`, not for the Play Store.
        apk.setKeyStore(sdk.createKeyStore(.example));
    }
    apk.setAndroidManifest(androidManifest(b));

    // The launcher icon is the window's (looks.icon), at 256 px; Android
    // scales it for the screen's density.
    const res = b.addWriteFiles();
    _ = res.addCopyDirectory(b.path("android/res"), "", .{});
    _ = res.addCopyFile(atlas.path(b, "icon-256.png"), "mipmap-xxxhdpi/ic_launcher.png");
    apk.addResourceDirectory(res.getDirectory());

    // Debug builds are too slow for the route planner's battle sims.
    const mode: std.builtin.Optimize = if (optimize == .debug) .small else optimize;
    var java_added = false;
    for (android.resolveTargets(b, .{ .default_target = b.graph.host, .all_targets = true, .api_level = .android9 })) |target| {
        if (!every_abi and target.result.cpu.arch != .aarch64) continue;
        const mod = sdlModule(b, target, mode, false, engine(b, target, romdata, false), atlas) orelse return;
        mod.strip = mode != .safe;
        if (!java_added) if (b.lazyDependency("sdl", .{ .target = target, .optimize = mode })) |sdl| {
            for (sdl.namedWriteFiles("java").copies.items) |copy| apk.addJavaSourceFile(.{ .file = copy.src_file });
            java_added = true;
        };
        apk.addArtifact(b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = mod }));
    }

    const installed = apk.addInstallApk();
    b.getInstallStep().dependOn(&installed.step);

    // zig-android-sdk's libc files (set by addInstallApk) lack darwin_sdk_dir,
    // which Zig 0.17.0 insists on: give every compile it set one on a whole one.
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    fixLibcFiles(b, apk, &installed.step, &seen);

    const start = sdk.addAdbStart(android_package ++ "/org.libsdl.app.SDLActivity");
    start.step.dependOn(&sdk.addAdbInstall(installed.source).step);
    b.step("run", "Install the APK on the device adb sees, and start it").dependOn(&start.step);
}

/// android/AndroidManifest.xml with build.zig.zon's version filled in, so
/// each release installs over the one before it.
fn androidManifest(b: *std.Build) std.Build.LazyPath {
    const version = comptime std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
    // Android compares versionCode, which must grow with every release.
    const code = version.major * 10000 + version.minor * 100 + version.patch;
    var manifest: []const u8 = @embedFile("android/AndroidManifest.xml");
    manifest = std.mem.replaceOwned(u8, b.allocator, manifest, "@VERSION_CODE@", b.fmt("{d}", .{code})) catch @panic("OOM");
    manifest = std.mem.replaceOwned(u8, b.allocator, manifest, "@VERSION_NAME@", b.fmt("{f}", .{version})) catch @panic("OOM");
    return b.addWriteFiles().add("AndroidManifest.xml", manifest);
}

/// Points every compile under `step` that has a libc file at one for its
/// target with all the fields Zig 0.17.0 reads, with the NDK paths
/// zig-android-sdk uses.
fn fixLibcFiles(b: *std.Build, apk: anytype, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((seen.getOrPut(b.graph.arena, step) catch @panic("OOM")).found_existing) return;
    for (step.dependencies.items) |dep| fixLibcFiles(b, apk, dep, seen);
    const compile = step.cast(std.Build.Step.Compile) orelse return;
    // Libraries linked through a module aren't step dependencies.
    for (compile.getCompileDependencies(false)) |dep| fixLibcFiles(b, apk, &dep.step, seen);
    if (compile.libc_file == null) return;
    const triple = switch (compile.root_module.resolved_target.?.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => "arm-linux-androideabi",
    };
    const sysroot = apk.ndk.sysroot_path;
    const crt_dir = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, @backingInt(apk.api_level) });
    compile.setLibCFile(b.addWriteFiles().add(b.fmt("libc-{s}.conf", .{triple}), b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir={s}
        \\darwin_sdk_dir=
        \\
    , .{ sysroot, sysroot, triple, crt_dir, crt_dir })));
}

/// The PortMaster package, in zig-out/portmaster: the native game for
/// aarch64 Linux handhelds, SDL3 built in, plus portmaster/'s launcher and
/// metadata and the licenses of what's bundled. `portmaster-zip` also zips
/// it into zig-out/drgnwrrr.zip.
fn addPortmaster(b: *std.Build, optimize: std.builtin.Optimize, romdata: std.Build.LazyPath, atlas: std.Build.LazyPath) void {
    const step = b.step("portmaster", "Build the PortMaster package (aarch64) into zig-out/portmaster");
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .gnu,
        // Old enough for the handhelds' firmwares.
        .glibc_version = .{ .major = 2, .minor = 30, .patch = 0 },
    });
    // Debug builds are too slow for the route planner's battle sims.
    const mode: std.builtin.Optimize = if (optimize == .debug) .fast else optimize;
    const exe = addSdlGame(b, target, mode, false, engine(b, target, romdata, false), atlas) orelse return;
    exe.root_module.strip = true;

    step.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "portmaster/drgnwrrr" } },
        .dest_sub_path = "drgnwrrr.aarch64",
    }).step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("portmaster/drgnwrrr"),
        .install_dir = .{ .custom = "portmaster/drgnwrrr" },
        .install_subdir = "",
    }).step);
    for ([_][2][]const u8{
        .{ "launch.sh", "drgnwrrr.sh" },
        .{ "port.json", "port.json" },
        .{ "gameinfo.xml", "gameinfo.xml" },
        .{ "README.md", "README.md" },
    }) |f| step.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("portmaster/{s}", .{f[0]})), .{ .custom = "portmaster" }, f[1]).step);

    const licenses: std.Build.InstallDir = .{ .custom = "portmaster/drgnwrrr/licenses" };
    for ([_][]const u8{ "LICENSE-kenney.txt", "LICENSE-kenney-input-prompts.txt", "LICENSE-anvil-font.md" }) |name|
        step.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("assets/{s}", .{name})), licenses, name).step);
    step.dependOn(&b.addInstallFileWithDir(b.path("LICENSE"), licenses, "LICENSE.drgnwrrr.txt").step);
    if (b.lazyDependency("sdl", .{})) |sdl| step.dependOn(&b.addInstallFileWithDir(sdl.path("LICENSE.txt"), licenses, "LICENSE.SDL3.txt").step);
    if (b.lazyDependency("clay", .{})) |clay| step.dependOn(&b.addInstallFileWithDir(clay.path("LICENSE.md"), licenses, "LICENSE.clay.md").step);

    // zig-out/drgnwrrr.zip, for a device's PortMaster autoinstall folder.
    // -FS drops entries for files no longer in zig-out/portmaster.
    const zip = b.addSystemCommand(&.{ "zip", "-qr", "-X", "-FS", "../drgnwrrr.zip", "." });
    zip.setCwd(.{ .relative = .{ .base = .install_prefix, .sub_path = "portmaster" } });
    zip.has_side_effects = true;
    zip.step.dependOn(step);
    b.step("portmaster-zip", "Build the PortMaster package and zip it into zig-out/drgnwrrr.zip").dependOn(&zip.step);
}
