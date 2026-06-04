const std = @import("std");
const cast = std.math.lossyCast;
const Elo = @import("sakana").Elo;

const clap = @import("clap");

const sqlite3 = @import("sqlite3.zig");
const p = @import("prompt.zig");

const reset = "\x1b[0m";

inline fn black(name: []const u8) []const u8 {
    return "\x1b[30m" ++ name ++ reset;
}
inline fn red(name: []const u8) []const u8 {
    return "\x1b[31m" ++ name ++ reset;
}
inline fn green(name: []const u8) []const u8 {
    return "\x1b[32m" ++ name ++ reset;
}
inline fn yellow(name: []const u8) []const u8 {
    return "\x1b[33m" ++ name ++ reset;
}
inline fn blue(name: []const u8) []const u8 {
    return "\x1b[34m" ++ name ++ reset;
}
inline fn magenta(name: []const u8) []const u8 {
    return "\x1b[35m" ++ name ++ reset;
}
inline fn cyan(name: []const u8) []const u8 {
    return "\x1b[36m" ++ name ++ reset;
}
inline fn white(name: []const u8) []const u8 {
    return "\x1b[37m" ++ name ++ reset;
}

const EloCommands = enum { ranks, promos, player, season, show };

const elo_params = clap.parseParamsComptime(
    \\-h, --help Display this help and exit.
    \\<command>
    \\
);

fn eloHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo ", .{name});
    try clap.usage(writer, clap.Help, &elo_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_params, .{});
    try writer.print(
        \\Available commands:
        \\    ranks  - random matches in all ranks
        \\    promos - promotion matches between ranks
        \\    player - play as one player
        \\    season - run ranks + promos
        \\    show   - show ranked players and positions
        \\
    , .{});
    try writer.flush();
}

const elo_ranks_params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\<str>                   Name of the league
    \\<usize>                 Number of games per rank
    \\
);

fn eloRanksHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo ranks ", .{name});
    try clap.usage(writer, clap.Help, &elo_ranks_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_ranks_params, .{});
    try writer.flush();
}

fn eloSeasonHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo season ", .{name});
    try clap.usage(writer, clap.Help, &elo_ranks_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_ranks_params, .{});
    try writer.flush();
}

const elo_promos_params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\<str>                   Name of the league
    \\
);

fn eloPromosHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo promos ", .{name});
    try clap.usage(writer, clap.Help, &elo_ranks_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_ranks_params, .{});
    try writer.flush();
}

const elo_player_params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\<str>                   Name of the league
    \\<usize>                 Player ID (REQUIRED)
    \\<usize>                 Number of games for the player (10)
    \\
);

fn eloPlayerHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo player ", .{name});
    try clap.usage(writer, clap.Help, &elo_player_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_player_params, .{});
    try writer.flush();
}

const elo_show_params = clap.parseParamsComptime(
    \\-h, --help              Display this help and exit.
    \\<str>                   Name of the league
    \\
);

fn eloShowHelp(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("uage: {s} elo show ", .{name});
    try clap.usage(writer, clap.Help, &elo_show_params);
    try writer.print("\n", .{});
    try clap.help(writer, clap.Help, &elo_show_params, .{});
    try writer.flush();
}

const Resource = struct {
    id: usize,
    string: []const u8,

    fn init(gpa: std.mem.Allocator, db: *sqlite3.SQLite3, id: usize) !Resource {
        const ResultType = struct {
            name: []const u8,
            release: []const u8,
            kind: []const u8,
            note: ?[]const u8,
        };
        var result = (try db.fetchOne2(gpa, ResultType, "SELECT name, release, kind, note FROM media WHERE id = ?", .{id})).?;

        defer {
            gpa.free(result.name);
            gpa.free(result.release);
            gpa.free(result.kind);
            if (result.note) |note| {
                gpa.free(note);
            }
        }
        return .{
            .id = id,
            .string = blk: {
                if (result.note) |note| {
                    break :blk try std.fmt.allocPrint(
                        gpa,
                        green("{s}") ++ magenta(" {s} ") ++ "({s}) ({s})",
                        .{ result.release[0..4], result.name, result.kind, note },
                    );
                } else {
                    break :blk try std.fmt.allocPrint(
                        gpa,
                        green("{s}") ++ magenta(" {s} ") ++ "({s})",
                        .{ result.release[0..4], result.name, result.kind },
                    );
                }
            },
        };
    }

    fn deinit(self: Resource, gpa: std.mem.Allocator) void {
        gpa.free(self.string);
    }
};

fn getResource(slice: []const Resource, id: usize) ?Resource {
    for (slice) |item| {
        if (item.id == id) {
            return item;
        }
    }
    return null;
}

fn userInput(
    gpa: std.mem.Allocator,
) !Elo.UserInput {
    while (true) {
        const c = try p.promptChar(gpa, "p1 win = h, p2 win = l, draw = j, undo = u, quit = q: ");
        const result: Elo.UserInput = switch (c) {
            'h' => .win,
            'l' => .lose,
            'j' => .draw,
            'u' => .undo,
            'q' => .quit,
            else => continue,
        };
        return result;
    }
}

const League = struct {
    id: usize,
    sql: []const u8,
};

fn play(
    init: std.process.Init,
    writer: *std.Io.Writer,
    database: *sqlite3.SQLite3,
    strategy: Elo.Strategy,
    league_name: []const u8,
) !void {
    const league = (try database.fetchOne2(init.gpa, League, "SELECT id, sql FROM league WHERE name = ?", .{league_name})).?;
    defer init.gpa.free(league.sql);
    const sql = try std.fmt.allocPrintSentinel(
        init.gpa,
        \\SELECT media.id, media.elo, COALESCE(rank.rank, 0) AS rank
        \\FROM media
        \\LEFT JOIN rank ON rank.media_id = media.id AND rank.league_id = ?
        \\WHERE {s}
    ,
        .{league.sql},
        0,
    );
    defer init.gpa.free(sql);

    var elo = try Elo.init(init.gpa, init.io, try database.fetchMany(
        init.gpa,
        Elo.Player,
        sql,
        .{league.id},
    ), strategy);
    defer elo.deinit();

    try elo.generate();

    var resources = std.ArrayList(Resource).empty;
    defer {
        for (resources.items) |item| item.deinit(init.gpa);
        resources.deinit(init.gpa);
    }

    {
        var chosen_ids = try elo.getChosenIds(init.gpa);
        defer chosen_ids.deinit(init.gpa);

        for (chosen_ids.items) |id| {
            try resources.append(init.gpa, try .init(init.gpa, database, id));
        }
    }

    while (try elo.next()) |action| {
        switch (action.*) {
            .match => |value| {
                try writer.print("{s} - {} " ++ red("vs") ++ " {s} - {}\n", .{
                    getResource(resources.items, elo.getId(value.player1)).?.string,
                    elo.getElo(value.player1),
                    getResource(resources.items, elo.getId(value.player2)).?.string,
                    elo.getElo(value.player2),
                });
                const result = try elo.act(try userInput(init.gpa), action);
                if (result) |r| {
                    try writer.print("{} - {}\n", r);
                }
            },
            .rank => |value| {
                try writer.print(yellow("{s}\n"), .{value.toString()});
            },
            .promotion => |value| {
                try writer.print("{s} from " ++ yellow("{s}") ++ " to " ++ yellow("{s}\n"), .{
                    getResource(resources.items, elo.getId(value.player)).?.string,
                    value.from.toString(),
                    value.to.toString(),
                });
            },
        }
    }

    var i = elo.result.iterator();
    while (i.next()) |entry| {
        const id = entry.key_ptr.*;
        const elo_value = entry.value_ptr.elo;
        const rank = entry.value_ptr.rank;
        database.execOne(
            "UPDATE media SET elo = ? WHERE id = ?",
            .{ elo_value, id },
        );
        database.execOne(
            \\INSERT INTO rank (league_id, media_id, rank)
            \\VALUES (?, ?, ?)
            \\ON CONFLICT(league_id, media_id)
            \\DO UPDATE SET rank = excluded.rank;
        , .{ league.id, id, rank });
    }
}

pub fn mainElo(
    init: std.process.Init,
    iter: *std.process.Args.Iterator,
    program_name: [:0]const u8,
    writer: *std.Io.Writer,
    database: *sqlite3.SQLite3,
) !void {
    const parsers = .{
        .command = clap.parsers.enumeration(EloCommands),
        .path = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &elo_params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        if (err == error.NameNotPartOfEnum) {
            try eloHelp(writer, program_name);
            return;
        }
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.positionals[0] == null) {
        try eloHelp(writer, program_name);
        return;
    }

    if (res.positionals[0]) |command| {
        switch (command) {
            .ranks => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &elo_ranks_params,
                    clap.parsers.default,
                    iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try eloRanksHelp(writer, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null) {
                    try eloRanksHelp(writer, program_name);
                    return;
                }

                const league_name = sub_res.positionals[0].?;
                const games_per_rank = sub_res.positionals[1] orelse 5;

                try play(
                    init,
                    writer,
                    database,
                    .{ .ranks = games_per_rank },
                    league_name,
                );
            },
            .promos => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &elo_promos_params,
                    clap.parsers.default,
                    iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try eloPromosHelp(writer, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null) {
                    try eloPromosHelp(writer, program_name);
                    return;
                }

                const league_name = sub_res.positionals[0].?;

                try play(init, writer, database, .promos, league_name);
            },
            .player => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &elo_player_params,
                    clap.parsers.default,
                    iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try eloPlayerHelp(writer, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null) {
                    try eloPlayerHelp(writer, program_name);
                    return;
                }

                const league_name = sub_res.positionals[0].?;
                const player_id = sub_res.positionals[1].?;
                const games_count = sub_res.positionals[2] orelse 10;

                try play(init, writer, database, .{ .player = .{
                    .id = player_id,
                    .count = games_count,
                } }, league_name);
            },
            .season => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &elo_ranks_params,
                    clap.parsers.default,
                    iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try eloSeasonHelp(writer, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null) {
                    try eloSeasonHelp(writer, program_name);
                    return;
                }

                const league_name = sub_res.positionals[0].?;
                const games_per_rank = sub_res.positionals[1] orelse 5;

                std.log.info("Ranks", .{});
                try play(
                    init,
                    writer,
                    database,
                    .{ .ranks = games_per_rank },
                    league_name,
                );
                std.log.info("Promotions", .{});
                try play(init, writer, database, .promos, league_name);
            },
            .show => {
                var sub_res = clap.parseEx(
                    clap.Help,
                    &elo_show_params,
                    clap.parsers.default,
                    iter,
                    .{ .diagnostic = &diag, .allocator = init.gpa },
                ) catch |err| {
                    if (err == error.InvalidArgument) {
                        try eloShowHelp(writer, program_name);
                        return;
                    }
                    try diag.reportToFile(init.io, .stderr(), err);
                    return err;
                };
                defer sub_res.deinit();

                if (sub_res.args.help != 0 or sub_res.positionals[0] == null) {
                    try eloShowHelp(writer, program_name);
                    return;
                }

                const league_name = sub_res.positionals[0].?;

                const league = (try database.fetchOne2(init.gpa, League, "SELECT id, sql FROM league WHERE name = ?", .{league_name})).?;
                defer init.gpa.free(league.sql);
                const sql = try std.fmt.allocPrintSentinel(
                    init.gpa,
                    \\SELECT media.id, media.elo, COALESCE(rank.rank, 0) AS rank
                    \\FROM media
                    \\LEFT JOIN rank ON rank.media_id = media.id AND rank.league_id = ?
                    \\WHERE {s} ORDER BY media.elo ASC
                ,
                    .{league.sql},
                    0,
                );
                defer init.gpa.free(sql);
                std.debug.print("{s}\n", .{sql});

                var players = try database.fetchMany(
                    init.gpa,
                    Elo.Player,
                    sql,
                    .{league.id},
                );
                defer players.deinit(init.gpa);

                var resources = std.ArrayList(Resource).empty;
                defer {
                    for (resources.items) |item| item.deinit(init.gpa);
                    resources.deinit(init.gpa);
                }

                for (players.items) |player| {
                    try resources.append(init.gpa, try .init(init.gpa, database, player.id));
                }

                inline for (@typeInfo(Elo.Rank).@"enum".fields) |field| {
                    const rank: Elo.Rank = @enumFromInt(field.value);
                    std.debug.print(yellow("{s}\n"), .{rank.toString()});
                    for (players.items) |player| {
                        if (player.rank == rank) {
                            try writer.print(
                                "{} - {s}\n",
                                .{ player.elo, getResource(resources.items, player.id).?.string },
                            );
                        }
                    }
                }
            },
        }
    }
}
