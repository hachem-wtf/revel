const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to ReleaseSafe because Debug pulls Zig's
    // UBSan runtime and other sanitization, which needs
    // f128/SSE ops, which i don't provide.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimize mode") orelse .ReleaseSafe;

    // The kernel must NOT touch SSE/MMX/AVX until it has 
    // enabled them itself, so I strip those features and 
    // let the compiler use a soft-float ABI. 
    // `code_model = .kernel` keeps relocations valid for 
    // the higher-half load address in boot/linker.ld.
    //
    // In other words. Going raw baby
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const Feature = std.Target.x86.Feature;
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));

    const kernel = b.addExecutable(.{
        .name = "revel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("boot/boot.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
            .code_model = .kernel,
            .red_zone = false,
            .single_threaded = true,
            .link_libc = false,
        }),
    });
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;
    kernel.setLinkerScript(b.path("boot/linker.ld"));

    b.installArtifact(kernel);
}
