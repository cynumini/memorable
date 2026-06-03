const std = @import("std");

const Self = @This();

const Score = enum {
    win,
    draw,
    lose,

    fn toFloat(self: Score) f32 {
        return switch (self) {
            .win => 1,
            .draw => 0.5,
            .lose => 0,
        };
    }
};

pub const UserInput = enum {
    win,
    lose,
    draw,
    undo,
    quit,

    fn getScore(self: UserInput) Score {
        return switch (self) {
            .win => .win,
            .lose => .lose,
            .draw => .draw,
            else => unreachable,
        };
    }
};

fn play(rating1: f32, rating2: f32, score: Score, k: f32) struct { f32, f32 } {
    const probability1 = 1.0 / (1.0 + std.math.pow(f32, 10, (rating2 - rating1) / 400.0));
    const probability2 = 1.0 - probability1;

    return .{
        rating1 + k * (score.toFloat() - probability1),
        rating2 + k * ((1.0 - score.toFloat()) - probability2),
    };
}

fn playInt(rating1: u32, rating2: u32, score: Score, k: f32) struct { u32, u32 } {
    const r = play(@floatFromInt(rating1), @floatFromInt(rating2), score, k);
    return .{ @round(r[0]), @round(r[1]) };
}

test play {
    var r = play(1200, 1000, .win, 30);
    try std.testing.expectEqual(1207, @round(r[0]));
    try std.testing.expectEqual(993, @round(r[1]));
    r = play(1500, 1400, .win, 32);
    try std.testing.expectEqual(1512, @round(r[0]));
    try std.testing.expectEqual(1388, @round(r[1]));
    r = play(1500, 1400, .lose, 32);
    try std.testing.expectEqual(1480, @round(r[0]));
    try std.testing.expectEqual(1420, @round(r[1]));
    r = play(1500, 1400, .draw, 32);
    try std.testing.expectEqual(1496, @round(r[0]));
    try std.testing.expectEqual(1404, @round(r[1]));
}

pub const Rank = enum {
    unranked,
    wood,
    stone,
    iron,
    gold,
    diamond,
    winner,

    pub fn toString(self: Rank) []const u8 {
        return switch (self) {
            .unranked => "Unranked",
            .wood => "Wood",
            .stone => "Stone",
            .iron => "Iron",
            .gold => "Gold",
            .diamond => "Diamond",
            .winner => "Winner",
        };
    }

    pub fn max(self: Rank) usize {
        return switch (self) {
            .unranked => std.math.maxInt(usize),
            .wood => 128,
            .stone => 64,
            .iron => 32,
            .gold => 16,
            .diamond => 8,
            .winner => 1,
        };
    }

    pub fn getPrev(self: Rank) Rank {
        return @enumFromInt(@intFromEnum(self) - 1);
    }
};

const Data = struct {
    elo: u32,
    rank: Rank,
};

pub const Player = struct { id: usize, elo: u32, rank: Rank };

pub const Action = union(enum) { rank: Rank, match: struct {
    player1: usize,
    player2: usize,
    score: ?Score = null,
    p1_elo: ?u32 = null,
    p2_elo: ?u32 = null,
}, promotion: struct {
    player: usize,
    from: Rank,
    to: Rank,
} };

pub const Strategy = union(enum) { ranks: usize, promos: void, player: struct {
    id: usize,
    count: usize,
} };

gpa: std.mem.Allocator,
players: std.ArrayList(Player) = .empty,
actions: std.ArrayList(Action) = .empty,
current_data: std.ArrayList(Data) = .empty,
result: std.AutoHashMap(usize, Data),
position: usize = 0,
strategy: Strategy,
prng: std.Random.DefaultPrng,

fn getDefaultPrng(io: std.Io) std.Random.DefaultPrng {
    const seed: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    return std.Random.DefaultPrng.init(seed);
}

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    players: std.ArrayList(Player),
    strategy: Strategy,
) !Self {
    var self = Self{
        .gpa = gpa,
        .players = players,
        .prng = getDefaultPrng(io),
        .result = .init(gpa),
        .strategy = strategy,
    };

    try self.current_data.ensureTotalCapacity(gpa, self.players.items.len);
    for (self.players.items) |player| {
        try self.current_data.append(
            gpa,
            .{ .elo = player.elo, .rank = player.rank },
        );
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.players.deinit(self.gpa);
    self.actions.deinit(self.gpa);
    self.current_data.deinit(self.gpa);
    self.result.deinit();
}

pub fn getId(self: *const Self, index: usize) usize {
    return self.players.items[index].id;
}

pub fn getInitElo(self: *const Self, index: usize) u32 {
    return self.players.items[index].elo;
}

pub fn getInitRank(self: *const Self, index: usize) Rank {
    return self.players.items[index].rank;
}

pub fn getData(self: *const Self, index: usize) Data {
    return self.current_data.items[index];
}

pub fn getElo(self: *const Self, index: usize) u32 {
    return self.current_data.items[index].elo;
}

pub fn getRank(self: *const Self, index: usize) Rank {
    return self.current_data.items[index].rank;
}

pub fn setElo(self: *Self, index: usize, value: u32) !void {
    const id = self.getId(index);
    self.current_data.items[index].elo = value;
    try self.result.put(id, self.current_data.items[index]);
}

pub fn setRank(self: *Self, index: usize, value: Rank) !void {
    const id = self.getId(index);
    self.current_data.items[index].rank = value;
    try self.result.put(id, self.current_data.items[index]);
}

fn getPlayersByRank(self: *const Self, rank: Rank) !std.ArrayList(usize) {
    var players: std.ArrayList(usize) = .empty;

    for (0..self.players.items.len) |index| {
        if (self.getRank(index) == rank) try players.append(self.gpa, index);
    }

    return players;
}

fn getBetterPlayers(self: *const Self, elo: usize) !std.ArrayList(usize) {
    var players: std.ArrayList(usize) = .empty;

    for (0..self.players.items.len) |index| {
        if (self.getElo(index) > elo) try players.append(self.gpa, index);
    }

    return players;
}

fn getStronger(self: *Self, self_index: usize, possible_players: []const usize) ?usize {
    const self_elo = self.players.items[self_index].elo;
    var stronger_index: ?usize = null;
    var stronger_elo: usize = std.math.maxInt(u32);
    for (possible_players) |index| {
        if (index == self_index) continue;
        const elo = self.players.items[index].elo;
        if (elo > self_elo and elo <= stronger_elo) {
            stronger_index = index;
            stronger_elo = elo;
        }
    }
    return stronger_index;
}

fn getWeaker(self: *Self, self_index: usize, possible_players: []const usize) ?usize {
    const self_elo = self.players.items[self_index].elo;
    var weaker_index: ?usize = null;
    var weaker_elo: usize = 0;
    for (possible_players) |index| {
        if (index == self_index) continue;
        const elo = self.players.items[index].elo;
        if (elo <= self_elo and elo >= weaker_elo) {
            weaker_index = index;
            weaker_elo = elo;
        }
    }
    return weaker_index;
}

fn generateRanks(self: *Self, games_per_rank: usize) !void {
    const random = self.prng.random();
    inline for (@typeInfo(Rank).@"enum".fields) |field| {
        const rank: Rank = @enumFromInt(field.value);
        if (rank == .winner) break;

        var possible_players = try self.getPlayersByRank(rank);
        defer possible_players.deinit(self.gpa);

        random.shuffle(usize, possible_players.items);

        const games_count = @min(games_per_rank, possible_players.items.len);

        if (games_count > 0 and possible_players.items.len > 2) {
            try self.actions.append(self.gpa, .{ .rank = rank });

            for (0..games_count) |i| {
                const player = possible_players.items[i];
                const opponent = blk: {
                    const stronger = self.getStronger(
                        player,
                        possible_players.items,
                    );
                    const weaker = self.getWeaker(
                        player,
                        possible_players.items,
                    );
                    if (stronger == null) break :blk weaker.?;
                    if (weaker == null) break :blk stronger.?;
                    break :blk if (random.boolean()) stronger.? else weaker.?;
                };
                try self.actions.append(self.gpa, .{ .match = .{
                    .player1 = player,
                    .player2 = opponent,
                } });
            }
        }
    }
}

const Sort = struct {
    fn lessThan(self: *Self, left: usize, right: usize) bool {
        const left_elo = self.getElo(left);
        const right_elo = self.getElo(right);
        return left_elo < right_elo;
    }

    fn moreThan(self: *Self, left: usize, right: usize) bool {
        return lessThan(self, right, left);
    }
};

fn generatePromos(self: *Self) !void {
    inline for (@typeInfo(Rank).@"enum".fields) |field| {
        const rank: Rank = @enumFromInt(field.value);
        if (rank == .unranked) continue;

        var current_rank_players = try self.getPlayersByRank(rank);
        defer current_rank_players.deinit(self.gpa);

        const prev_rank = rank.getPrev();

        var prev_rank_players = try self.getPlayersByRank(prev_rank);
        defer prev_rank_players.deinit(self.gpa);

        std.mem.sort(usize, prev_rank_players.items, self, Sort.lessThan);

        if (current_rank_players.items.len < rank.max()) {
            try self.actions.append(self.gpa, .{ .rank = rank });
            while (prev_rank_players.pop()) |index| {
                if (current_rank_players.items.len < rank.max()) {
                    try current_rank_players.append(self.gpa, index);
                    try self.setRank(index, rank);
                    try self.actions.append(self.gpa, .{ .promotion = .{
                        .player = index,
                        .from = prev_rank,
                        .to = rank,
                    } });
                }
            }
        } else {
            try self.actions.append(self.gpa, .{ .rank = rank });
            std.mem.sort(usize, current_rank_players.items, self, Sort.moreThan);
            const current_worst = current_rank_players.pop().?;
            const prev_best = prev_rank_players.pop().?;
            try self.actions.append(self.gpa, .{ .match = .{
                .player1 = current_worst,
                .player2 = prev_best,
            } });
        }
    }
}

fn getIndexFromId(self: *const Self, id: usize) ?usize {
    for (0.., self.players.items) |index, player| {
        if (player.id == id) {
            return index;
        }
    }
    return null;
}

fn generatePlayer(self: *Self, player_id: usize, games_count: usize) !void {
    const random = self.prng.random();

    if (self.getIndexFromId(player_id)) |player| {
        var players = try self.getBetterPlayers(self.getElo(player));
        defer players.deinit(self.gpa);

        random.shuffle(usize, players.items);

        const len = @min(games_count, players.items.len);

        for (0..len) |i| {
            try self.actions.append(self.gpa, .{ .match = .{
                .player1 = player,
                .player2 = players.items[i],
            } });
        }
    } else {
        std.log.err("Player with id = {} doesn't exist", .{player_id});
    }
}

pub fn generate(self: *Self) !void {
    switch (self.strategy) {
        .ranks => |value| try self.generateRanks(value),
        .promos => try self.generatePromos(),
        .player => |value| try self.generatePlayer(value.id, value.count),
    }
}

pub fn next(self: *Self) !?*Action {
    if (self.position == self.actions.items.len) {
        return null;
    }
    const action = &self.actions.items[self.position];
    if (action.* == .rank or action.* == .promotion) {
        self.position += 1;
    }
    return action;
}

fn getAction(self: *Self) ?*Action {
    return &self.actions.items[self.position];
}

pub fn act(self: *Self, user_input: UserInput, action: *Action) !?struct { u32, u32 } {
    switch (user_input) {
        .win, .lose, .draw => |value| {
            const match = &action.match;
            match.p1_elo = self.getElo(match.player1);
            match.p2_elo = self.getElo(match.player2);
            match.score = value.getScore();
            const r = playInt(
                match.p1_elo.?,
                match.p2_elo.?,
                match.score.?,
                32,
            );
            try self.setElo(match.player1, r[0]);
            try self.setElo(match.player2, r[1]);

            if (match.score == .lose and self.strategy == .promos) {
                const rank1 = self.getRank(match.player1);
                const rank2 = self.getRank(match.player2);
                try self.setRank(match.player1, rank2);
                try self.setRank(match.player2, rank1);
            }
            self.position += 1;
            return r;
        },
        .quit => {
            self.position = self.actions.items.len;
        },
        .undo => {
            while (true) {
                if (self.position > 0) {
                    self.position -= 1;
                    const a = self.getAction();
                    if (a == null) break;
                    if (a.?.* != .match) {
                        continue;
                    }
                    const match = &a.?.match;
                    try self.setElo(match.player1, match.p1_elo.?);
                    try self.setElo(match.player2, match.p2_elo.?);
                    break;
                }
                break;
            }
        },
    }
    return null;
}

fn addUnique(array: *std.ArrayList(usize), gpa: std.mem.Allocator, value: usize) !void {
    var unique = true;
    for (array.items) |item| {
        if (item == value) {
            unique = false;
        }
    }
    if (unique) {
        try array.append(gpa, value);
    }
}

pub fn getChosenIds(self: *Self, gpa: std.mem.Allocator) !std.ArrayList(usize) {
    var result = std.ArrayList(usize).empty;
    for (self.actions.items) |action| {
        switch (action) {
            .match => |value| {
                try addUnique(&result, gpa, self.getId(value.player1));
                try addUnique(&result, gpa, self.getId(value.player2));
            },
            .promotion => |value| {
                try addUnique(&result, gpa, self.getId(value.player));
            },
            else => {},
        }
    }
    std.mem.sort(usize, result.items, {}, std.sort.asc(usize));
    return result;
}

pub fn printAll(self: *Self) void {
    for (self.players.items) |player| {
        std.debug.print("{} {} {}\n", .{ player.id, player.elo, player.rank });
    }
}

pub fn printAction(self: *Self, action: Action) void {
    switch (action) {
        .rank => |value| std.debug.print("{}\n", .{value}),
        .promotion => |value| {
            const p = self.players.items[value.player];
            std.debug.print("{} from {} to {}\n", .{ p, value.from, value.to });
        },
        .match => |value| {
            const p1 = self.players.items[value.player1];
            const p2 = self.players.items[value.player2];
            std.debug.print("{} vs  {}\n", .{ p1, p2 });
        },
    }
}

pub fn printQueue(self: *Self) void {
    for (self.actions.items) |action| self.printAction(action);
}
