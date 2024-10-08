const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const config = @import("config.zig");

const ray = @import("raylib.zig");
const Game = @import("Game.zig");

const dll_name = build_options.install_path ++ "/" ++ config.game_name ++ ".dll";
const temp_dll_name = build_options.install_path ++ "/" ++ config.game_name ++ "-temp.dll";
var dll: std.DynLib = undefined;

const dll_watch_path = blk: {
    var str: [build_options.install_path.len]u8 = undefined;
    @memcpy(&str, build_options.install_path);
    std.mem.replaceScalar(u8, &str, '/', '\\');
    const final = str;
    break :blk &final;
};
var dll_watcher_thread: std.Thread = undefined;
var dll_change_detected = false;

const asset_watch_path = config.asset_dir_name;
var asset_watcher_thread: std.Thread = undefined;
var asset_change_detected = false;

pub var init_fn: if (build_options.static) void else *@TypeOf(Game.initWrapper) = undefined;
pub var update_fn: if (build_options.static) void else *@TypeOf(Game.updateWrapper) = undefined;

pub fn update(game: *Game, allocator: Allocator) !void {
    if (config.reload_key != null and ray.IsKeyPressed(config.reload_key.?)) {
        // Force reload
        dll_change_detected = true;
    }

    if (dll_change_detected) {
        try dllReload();
        try spawnDLLWatcher();
    }

    if (asset_change_detected) {
        game.assets.deinit();
        // Reloading sometimes fails, presumably because whatever edited the file locks it. Retry several times.
        for (0..10) |_| {
            game.assets.init() catch {
                std.time.sleep(0.01 * std.time.ns_per_s);
                continue;
            };
            break;
        } else {
            return error.AssetLoadError;
        }
        try spawnAssetWatcher();
    }

    if (config.restart_key != null and ray.IsKeyPressed(config.restart_key.?)) {
        // Restart game
        game.deinit(false);
        game.* = .{
            .allocator = allocator,
        };
        if (init_fn(game, false) != 0) return error.InitializationError;
    }

    if (update_fn(game) != 0) return error.UpdateError;
}

pub fn dllOpen() !void {
    const dir = std.fs.cwd();
    try dir.copyFile(dll_name, dir, temp_dll_name, .{});
    dll = try std.DynLib.open(temp_dll_name);

    init_fn = dll.lookup(@TypeOf(init_fn), "initWrapper") orelse return error.FunctionNotFound;
    update_fn = dll.lookup(@TypeOf(update_fn), "updateWrapper") orelse return error.FunctionNotFound;
}

pub fn dllClose() void {
    dll.close();
}

pub fn dllReload() !void {
    dllClose();
    try dllOpen();
}

pub fn spawnAssetWatcher() !void {
    asset_change_detected = false;
    asset_watcher_thread = std.Thread.spawn(.{}, watcher, .{ asset_watch_path, &asset_change_detected }) catch unreachable;
    asset_watcher_thread.detach();
}

pub fn spawnDLLWatcher() !void {
    dll_change_detected = false;
    dll_watcher_thread = std.Thread.spawn(.{}, watcher, .{ dll_watch_path, &dll_change_detected }) catch unreachable;
    dll_watcher_thread.detach();
}

fn watcher(dir_path: []const u8, out: *bool) void {
    var dirname_path_space: std.os.windows.PathSpace = undefined;
    dirname_path_space.len = std.unicode.utf8ToUtf16Le(&dirname_path_space.data, dir_path) catch unreachable;
    dirname_path_space.data[dirname_path_space.len] = 0;
    const dir_handle = std.os.windows.OpenFile(dirname_path_space.span(), .{
        .dir = std.fs.cwd().fd,
        .access_mask = std.os.windows.GENERIC_READ,
        .creation = std.os.windows.FILE_OPEN,
        .filter = .dir_only,
        .follow_symlinks = false,
    }) catch |err| {
        std.debug.print("Error in opening file: {any}\n", .{err});
        unreachable;
    };
    var event_buf: [4096]u8 align(@alignOf(std.os.windows.FILE_NOTIFY_INFORMATION)) = undefined;
    var num_bytes: u32 = 0;
    _ = std.os.windows.kernel32.ReadDirectoryChangesW(
        dir_handle,
        &event_buf,
        event_buf.len,
        std.os.windows.TRUE,
        std.os.windows.FileNotifyChangeFilter{
            .file_name = true,
            .dir_name = true,
            .attributes = true,
            .size = true,
            .last_write = true,
            .last_access = true,
            .creation = true,
            .security = true,
        },
        &num_bytes,
        null,
        null,
    );
    out.* = true;
}
