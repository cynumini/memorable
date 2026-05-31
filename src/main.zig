const std = @import("std");
const sqlite3 = @import("sqlite3.zig");
const rl = @import("readline.zig");
const clap = @import("clap");

// fn getDefaultPrng(io: std.Io) std.Random.DefaultPrng {
//     const seed: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
//     return std.Random.DefaultPrng.init(seed);
// }

// fn sql_entry_func(text: [*:0]const u8, index: c_int) ?[*:0]u8 {
//     if (index == 0) {
//         sql_entry_func_stmt.?.reset();
//         const parameter = std.fmt.allocPrintSentinel(
//             arena,
//             "{s}%",
//             .{text},
//             0,
//         ) catch unreachable;
//         sql_entry_func_stmt.bindText(1, parameter, .transient);
//     }
//     const result = sql_entry_func_stmt.step();
//     if (result == .row) {
//         const value = sql_entry_func_stmt.columnText(0);
//         return std.c.strdup(value);
//     } else if (result == .done) {
//         return null;
//     }
//     unreachable;
// }

// fn sql_completion_function(text: [*c]const u8, start: c_int, end: c_int) callconv(.c) [*c][*c]u8 {
//     _ = start;
//     _ = end;
//     _ = rl.bindKey('\t', rl.complete);
//     rl.rl_attempted_completion_over = 1;
//     rl.rl_completion_append_character = 0;
//     rl.rl_completer_word_break_characters = "";
//     return rl.completionMatches(text, sql_entry_func);
// }

// var sql_entry_func_stmt: ?*sqlite3.Statement = null;

const main_params = clap.parseParamsComptime(
    \\-h, --help            Display this help and exit.
    \\-d, --database <path> Path to the database file.
    \\<command>
    \\
);

const Commands = enum { add, elo, log, stats };

const main_parsers = .{
    .command = clap.parsers.enumeration(Commands),
    .path = clap.parsers.string,
};

fn mainHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} ", .{name});
    try clap.usage(writer, clap.Help, &main_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &main_params, .{});
    try writer.print(
        \\Available commands:
        \\    add   - Add media to the database
        \\    elo   - Play elo matches between media
        \\    log   - Log media
        \\    stats - Show stats
        \\
    , .{});
    try writer.flush();
}

const add_params = clap.parseParamsComptime(
    \\-h, --help           Display this help and exit.
    \\-n, --name <str>     Media title.
    \\-k, --kind <str>     Media type (Anime, Manga, LN, VN, Game, ...).
    \\-r, --release <date> Original release date
    \\-j, --japanese       Media was originally released in Japanese?
    \\-s, --state <state>  Status: new, repeat, completed.
    \\-o, --note <str>     Additional notes or comments.
);

fn addUsage(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} add ", .{name});
    try clap.usage(writer, clap.Help, &add_params);
    try writer.print("\n\n", .{});
    try clap.help(writer, clap.Help, &add_params, .{});
    try writer.flush();
}

fn migrate(database: *sqlite3.SQLite3) void {
    const version = database.fetchOne(i32, "PRAGMA user_version;");
    if (version == 0) {
        std.log.info("Creating the database", .{});
        const sql =
            \\BEGIN;
            \\CREATE TABLE media (
            \\    id       INTEGER NOT NULL UNIQUE,
            \\    name     TEXT NOT NULL,
            \\    kind     TEXT NOT NULL,
            \\    release  TEXT NOT NULL,
            \\    elo      INT NOT NULL DEFAULT 1000,
            \\    japanese INT NOT NULL,
            \\    state    INT NOT NULL DEFAULT 0,
            \\    note     TEXT,
            \\    rank     INTEGER NOT NULL DEFAULT 0,
            \\    PRIMARY KEY(id AUTOINCREMENT),
            \\    UNIQUE(name,kind)
            \\) STRICT;
            \\CREATE TABLE log (
            \\    id               INTEGER NOT NULL UNIQUE,
            \\    timestamp        REAL NOT NULL UNIQUE,
            \\    kind             TEXT NOT NULL,
            \\    duration_seconds INTEGER NOT NULL,
            \\    parent_id        INTEGER,
            \\    characters       INTEGER,
            \\    page             INTEGER,
            \\    eps              REAL,
            \\    yt_id            TEXT,
            \\    yt_title         TEXT,
            \\    notes            TEXT,
            \\    PRIMARY KEY(id AUTOINCREMENT),
            \\    FOREIGN KEY(parent_id) REFERENCES media(id)
            \\) STRICT;
            \\PRAGMA user_version = 1;
            \\COMMIT;
        ;
        database.exec(sql, null, null);
    }
}

var prompt_sql_stmt: ?*sqlite3.Statement = null;
var prompt_sql_allocator: ?std.mem.Allocator = null;

fn promptSQLCompentryFunc(text: [*:0]const u8, index: c_int) callconv(.c) ?[*:0]u8 {
    if (index == 0) {
        prompt_sql_stmt.?.reset();
        const value = std.fmt.allocPrintSentinel(
            prompt_sql_allocator.?,
            "{s}%",
            .{text},
            0,
        ) catch unreachable;
        prompt_sql_stmt.?.bindText(1, value, .transient);
    }
    const result = prompt_sql_stmt.?.step();
    if (result == .row) {
        return std.heap.c_allocator.dupeZ(u8, prompt_sql_stmt.?.column([:0]const u8, 0)) catch unreachable;
    } else if (result == .done) {
        return null;
    } else unreachable;
}

fn promptSQLCompletionFunc(text: [*:0]const u8, _: c_int, _: c_int) callconv(.c) ?[*:null]?[*:0]u8 {
    rl.bindKey('\t', rl.complete);
    rl.setAttemptedCompletionOver(1);
    rl.setCompletionAppendCharacter(0);
    rl.setCompleterWordBreakCharacters("");
    return rl.completionMatches(text, promptSQLCompentryFunc);
}

fn promptSQL(allocator: std.mem.Allocator, prompt: [:0]const u8, db: *sqlite3.SQLite3, sql: [:0]const u8) ![]const u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    prompt_sql_allocator = scratch_arena.allocator();

    prompt_sql_stmt = db.prepare(sql);
    defer prompt_sql_stmt.?.finalize();
    rl.setAttemptedCompletionFunction(promptSQLCompletionFunc);
    const string = try rl.readline(allocator, prompt);
    return std.mem.trim(u8, string, " ");
}

pub fn main(init: std.process.Init) !void {
    var writer = std.Io.File.Writer.init(.stdout(), init.io, &.{});

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    const program_name = iter.next().?;

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        if (err == error.NameNotPartOfEnum) {
            try mainHelp(&writer.interface, program_name);
            return;
        }
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.positionals[0] == null) {
        try mainHelp(&writer.interface, program_name);
        return;
    }

    const database_path = try init.gpa.dupeSentinel(u8, blk: {
        if (res.args.database) |database_path| break :blk database_path;
        if (init.environ_map.get("OMOSHIROI_DB_PATH")) |database_path| {
            break :blk database_path;
        }
        break :blk "omoshiroi.db";
    }, 0);
    defer init.gpa.free(database_path);

    std.log.info("The database path is \"{s}\"", .{database_path});

    var database = sqlite3.open(database_path);
    defer database.close();

    migrate(database);

    //     var prng = getDefaultPrng(init.io);
    //     const random = prng.random();
    //     _ = random;

    if (res.positionals[0]) |command| {
        switch (command) {
            .add => {
                const State = enum { new, repeat, completed };
                const parsers = comptime .{
                    .str = clap.parsers.string,
                    .date = clap.parsers.string,
                    .state = clap.parsers.enumeration(State),
                };
                var sub_res = clap.parseEx(
                    clap.Help,
                    &add_params,
                    &parsers,
                    &iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try addUsage(&writer.interface, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0) {
                    try addUsage(&writer.interface, program_name);
                    return;
                }

                const name = try promptSQL(
                    init.gpa,
                    "Name: ",
                    database,
                    "SELECT name FROM media WHERE name LIKE ?",
                );
                defer init.gpa.free(name);
                const kind = try promptSQL(
                    init.gpa,
                    "Kind: ",
                    database,
                    "SELECT DISTINCT kind FROM media WHERE kind LIKE ?",
                );
                defer init.gpa.free(kind);

                std.debug.print("{s}\n", .{name});
            },
            .elo => {},
            .log => {},
            .stats => {},
        }
    }
}
