const std = @import("std");

const clap = @import("clap");

const elo_command = @import("elo-command.zig");
const p = @import("prompt.zig");
const sqlite3 = @import("sqlite3.zig");

const MainCommands = enum { add, elo, league, log, stats };

const main_params = clap.parseParamsComptime(
    \\-h, --help            Display this help and exit.
    \\-d, --database <path> Path to the database file.
    \\<command>
    \\
);

fn mainHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} ", .{name});
    try clap.usage(writer, clap.Help, &main_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &main_params, .{});
    try writer.print(
        \\Available commands:
        \\    add    - Add media to the database
        \\    elo    - Play elo matches between media
        \\    league - Add a new league
        \\    log    - Log media
        \\    stats  - Show stats
        \\
    , .{});
    try writer.flush();
}

const add_params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\-n, --name <str>        Media title.
    \\-k, --kind <str>        Media type (Anime, Manga, LN, VN, Game, ...).
    \\-r, --release <date>    Original release date
    \\-j, --japanese <answer> Media was originally released in Japanese?
    \\-s, --state <state>     Status: new, repeat, completed.
    \\-o, --note <str>        Additional notes or comments.
);

fn addHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} add ", .{name});
    try clap.usage(writer, clap.Help, &add_params);
    try writer.print("\n\n", .{});
    try clap.help(writer, clap.Help, &add_params, .{});
    try writer.flush();
}

const league_params = clap.parseParamsComptime(
    \\-h, --help Display this help and exit.
    \\<str>      Name of the league
    \\<str>      SQL query
);

fn leagueHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} league ", .{name});
    try clap.usage(writer, clap.Help, &league_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &league_params, .{});
    try writer.flush();
}

fn migrate(database: *sqlite3.SQLite3) void {
    const version = database.fetchOne(i32, "PRAGMA user_version;", .{});
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
    if (version == 1) {
        std.log.info("Migrate the database to version 2", .{});
        const sql =
            \\BEGIN;
            \\CREATE TABLE league (
            \\    id   INTEGER NOT NULL UNIQUE,
            \\    name TEXT NOT NULL UNIQUE,
            \\    sql  TEXT NOT NULL UNIQUE,
            \\    PRIMARY KEY(id AUTOINCREMENT)
            \\) STRICT;
            \\INSERT INTO league (id, name, sql) VALUES (1, "all", "media.state != 2");
            \\INSERT INTO league (id, name, sql) VALUES (2, "japanese", "media.state != 2 AND media.japanese = 1");
            \\INSERT INTO league (id, name, sql) VALUES (3, "english", "media.state != 2 AND media.japanese = 0");
            \\CREATE TABLE rank (
            \\    league_id INTEGER NOT NULL,
            \\    media_id  INTEGER NOT NULL,
            \\    rank      INTEGER NOT NULL,
            \\    UNIQUE(league_id,media_id),
            \\    FOREIGN KEY(league_id) REFERENCES league(id),
            \\    FOREIGN KEY(media_id) REFERENCES media(id)
            \\) STRICT;
            \\INSERT INTO rank (league_id, media_id, rank)
            \\       SELECT 1, id, rank FROM media;
            \\ALTER TABLE media DROP COLUMN rank;
            \\PRAGMA user_version = 2;
            \\COMMIT;
        ;
        database.exec(sql, null, null);
    }
}

pub fn main(init: std.process.Init) !void {
    var writer = std.Io.File.Writer.init(.stdout(), init.io, &.{});

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    const program_name = iter.next().?;

    const main_parsers = .{
        .command = clap.parsers.enumeration(MainCommands),
        .path = clap.parsers.string,
    };

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

    if (res.positionals[0]) |command| {
        switch (command) {
            .add => {
                const State = enum { new, repeat, completed };
                const Answer = enum { y, n };
                const add_parsers = .{
                    .str = clap.parsers.string,
                    .date = clap.parsers.string,
                    .state = clap.parsers.enumeration(State),
                    .answer = clap.parsers.enumeration(Answer),
                };
                var sub_res = clap.parseEx(
                    clap.Help,
                    &add_params,
                    &add_parsers,
                    &iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try addHelp(&writer.interface, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0) {
                    try addHelp(&writer.interface, program_name);
                    return;
                }

                var scratch_arena = std.heap.ArenaAllocator.init(init.gpa);
                defer scratch_arena.deinit();

                const gpa = scratch_arena.allocator();

                const name = sub_res.args.name orelse try p.promptSQL(
                    gpa,
                    "Name: ",
                    database,
                    "SELECT name FROM media WHERE name LIKE ?",
                );

                const kind = sub_res.args.kind orelse try p.promptSQL(
                    gpa,
                    "Kind: ",
                    database,
                    "SELECT DISTINCT kind FROM media WHERE kind LIKE ?",
                );

                const release =
                    if (sub_res.args.release) |r| (try p.textToISODate(
                        gpa,
                        r,
                    )).? else try p.promptDate(gpa, "Release: ");

                const japanese = blk: {
                    var result: ?bool = null;
                    if (sub_res.args.japanese) |j| {
                        result = j == .y;
                    }
                    break :blk result orelse try p.promptCheck(
                        gpa,
                        "Will I consume it in Japanese? (Y/n): ",
                        .{ .default = true, .default_value = true },
                    );
                };

                const state: State = blk: {
                    var result: ?State = sub_res.args.state;
                    if (result) |r| break :blk r;
                    result = State.new;
                    if (try p.promptCheck(gpa, "Completed? (y/N): ", .{ .default = true }))
                        result = if (try p.promptCheck(
                            gpa,
                            "Want to re-experience? (y/N): ",
                            .{ .default = true },
                        )) .repeat else .completed;
                    break :blk result.?;
                };

                const note: ?[]const u8 = blk: {
                    const result = sub_res.args.note orelse try p.prompt(
                        gpa,
                        "Note: ",
                        true,
                    );
                    break :blk if (result.len == 0) null else result;
                };

                database.execOne(
                    \\INSERT INTO media (name, kind, release, japanese, state, note)
                    \\       VALUES (?, ?, ?, ?, ?, ?)
                , .{ name, kind, release, japanese, state, note });
            },
            .elo => try elo_command.mainElo(
                init,
                &iter,
                program_name,
                &writer.interface,
                database,
            ),
            .league => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &league_params,
                    clap.parsers.default,
                    &iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try leagueHelp(&writer.interface, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null or sub_res.positionals[1] == null) {
                    try leagueHelp(&writer.interface, program_name);
                    return;
                }

                const name: []const u8 = sub_res.positionals[0].?;
                const sql: []const u8 = sub_res.positionals[1].?;

                database.execOne("INSERT INTO league (name, sql) VALUES (?, ?)", .{ name, sql });
            },
            .log => {},
            .stats => {},
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
