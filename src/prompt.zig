const std = @import("std");
const rl = @import("readline.zig");
const sqlite3 = @import("sqlite3.zig");

const PromptSQL = struct {
    var statement: ?*sqlite3.Statement = null;
    var allocator: ?std.mem.Allocator = null;

    fn compentryFunc(text: [*:0]const u8, index: c_int) callconv(.c) ?[*:0]u8 {
        if (index == 0) {
            statement.?.reset();
            const value = std.fmt.allocPrintSentinel(
                allocator.?,
                "{s}%",
                .{text},
                0,
            ) catch unreachable;
            statement.?.bindText(1, value, .transient);
        }
        const result = statement.?.step();
        if (result == .row) {
            return std.heap.c_allocator.dupeZ(u8, statement.?.column([:0]const u8, 0)) catch unreachable;
        } else if (result == .done) {
            return null;
        } else unreachable;
    }

    fn completionFunc(text: [*:0]const u8, _: c_int, _: c_int) callconv(.c) ?[*:null]?[*:0]u8 {
        rl.bindKey('\t', rl.complete);
        rl.setAttemptedCompletionOver(1);
        rl.setCompletionAppendCharacter(0);
        rl.setCompleterWordBreakCharacters("");
        return rl.completionMatches(text, compentryFunc);
    }
};

pub fn promptSQL(allocator: std.mem.Allocator, message: [:0]const u8, db: *sqlite3.SQLite3, sql: [:0]const u8) ![]const u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    PromptSQL.allocator = scratch_arena.allocator();

    PromptSQL.statement = db.prepare(sql);
    defer PromptSQL.statement.?.finalize();

    rl.setAttemptedCompletionFunction(PromptSQL.completionFunc);

    const string = try rl.readline(allocator, message);
    return std.mem.trim(u8, string, " ");
}

const TextToISODate = struct {
    const Date = struct {
        year: u32,
        month: u32,
        day: u32,

        fn toString(self: Date, gpa: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(
                gpa,
                "{:0>4}-{:0>2}-{:0>2}",
                .{ self.year, self.month, self.day },
            );
        }
    };

    const Token = struct { text: []const u8, kind: enum { number, text } };

    const State = enum { start, number, text };

    fn addToken(
        gpa: std.mem.Allocator,
        tokens: *std.ArrayList(Token),
        state: State,
        text: []const u8,
        start: usize,
        end: usize,
    ) !void {
        if (end > start) {
            try tokens.append(gpa, .{
                .kind = if (state == .number) .number else .text,
                .text = text[start..end],
            });
        }
    }

    fn tokenizer(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token).empty;
        const v = try std.unicode.Utf8View.init(text);
        var i = v.iterator();
        var end: usize = 0;
        var token_start: usize = 0;
        var state = State.start;
        while (i.nextCodepointSlice()) |c| {
            end += c.len;
            const next_state: State = blk: {
                if (c.len == 1) {
                    if (std.ascii.isDigit(c[0])) break :blk .number;
                    if (std.ascii.isWhitespace(c[0])) break :blk .start;
                }
                break :blk .text;
            };
            if (state != .start and state != next_state) {
                const token_end = end - c.len;
                try addToken(gpa, &tokens, state, text, token_start, token_end);
                token_start = token_end;
            }
            if (next_state == .start) token_start += 1;
            state = next_state;
        } else {
            try addToken(gpa, &tokens, state, text, token_start, end);
        }
        return tokens;
    }

    fn validateChar(token: Token, char: u8) bool {
        return token.kind == .text and token.text.len == 1 and token.text[0] == char;
    }

    fn validateSlice(token: Token, slice: []const u8) bool {
        return token.kind == .text and std.mem.eql(u8, token.text, slice);
    }

    fn validateNumber(token: Token) ?u32 {
        if (token.kind != .number) return null;
        return std.fmt.parseInt(u32, token.text, 10) catch return null;
    }

    fn fromISODate(tokens: std.ArrayList(Token)) ?Date {
        if (tokens.items.len != 5) return null;
        if (!validateChar(tokens.items[1], '-') or !validateChar(tokens.items[3], '-')) return null;
        return .{
            .year = validateNumber(tokens.items[0]) orelse return null,
            .month = validateNumber(tokens.items[2]) orelse return null,
            .day = validateNumber(tokens.items[4]) orelse return null,
        };
    }

    fn validateMonth(t: Token) ?u32 {
        if (t.kind != .text) return null;
        const m = t.text;
        if (std.mem.eql(u8, m, "Jan") or std.mem.eql(u8, m, "January")) return 1;
        if (std.mem.eql(u8, m, "Feb") or std.mem.eql(u8, m, "February")) return 2;
        if (std.mem.eql(u8, m, "Mar") or std.mem.eql(u8, m, "March")) return 3;
        if (std.mem.eql(u8, m, "Apr") or std.mem.eql(u8, m, "April")) return 4;
        if (std.mem.eql(u8, m, "May")) return 5;
        if (std.mem.eql(u8, m, "Jun") or std.mem.eql(u8, m, "June")) return 6;
        if (std.mem.eql(u8, m, "Jul") or std.mem.eql(u8, m, "July")) return 7;
        if (std.mem.eql(u8, m, "Aug") or std.mem.eql(u8, m, "August")) return 8;
        if (std.mem.eql(u8, m, "Sep") or std.mem.eql(u8, m, "September")) return 9;
        if (std.mem.eql(u8, m, "Oct") or std.mem.eql(u8, m, "October")) return 10;
        if (std.mem.eql(u8, m, "Nov") or std.mem.eql(u8, m, "November")) return 11;
        if (std.mem.eql(u8, m, "Dec") or std.mem.eql(u8, m, "December")) return 12;
        return null;
    }

    fn fromUSDate(tokens: std.ArrayList(Token)) ?Date {
        if (tokens.items.len != 4) return null;
        if (!validateChar(tokens.items[2], ',')) return null;
        return .{
            .year = validateNumber(tokens.items[3]) orelse return null,
            .month = validateMonth(tokens.items[0]) orelse return null,
            .day = validateNumber(tokens.items[1]) orelse return null,
        };
    }

    fn fromJPDate(tokens: std.ArrayList(Token)) ?Date {
        if (tokens.items.len != 6) return null;
        if (!validateSlice(tokens.items[1], "年")) return null;
        if (!validateSlice(tokens.items[3], "月")) return null;
        if (!validateSlice(tokens.items[5], "日")) return null;
        return .{
            .year = validateNumber(tokens.items[0]) orelse return null,
            .month = validateNumber(tokens.items[2]) orelse return null,
            .day = validateNumber(tokens.items[4]) orelse return null,
        };
    }
};

pub fn textToISODate(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const tokens = try TextToISODate.tokenizer(scratch, text);
    var date = TextToISODate.fromISODate(tokens);
    if (date == null) date = TextToISODate.fromUSDate(tokens);
    if (date == null) date = TextToISODate.fromJPDate(tokens);
    if (date) |d| return try d.toString(allocator);
    return null;
}

pub fn promptDate(allocator: std.mem.Allocator, message: [:0]const u8) ![]const u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    const scratch = scratch_arena.allocator();

    rl.bindKey('\t', rl.insert);
    while (true) {
        const string = try rl.readline(scratch, message);
        if (try textToISODate(allocator, string)) |date|
            return date;
    }
}

test textToISODate {
    const gpa = std.testing.allocator;

    const test1 = try textToISODate(gpa, "1995-12-01");
    defer gpa.free(test1.?);
    try std.testing.expectEqualStrings("1995-12-01", test1.?);

    const test2 = try textToISODate(gpa, "November 11, 2011");
    defer gpa.free(test2.?);
    try std.testing.expectEqualStrings("2011-11-11", test2.?);

    const test3 = try textToISODate(gpa, "Sep 25, 2015");
    defer gpa.free(test3.?);
    try std.testing.expectEqualStrings("2015-09-25", test3.?);

    const test4 = try textToISODate(gpa, "2011年11月11日");
    defer gpa.free(test4.?);
    try std.testing.expectEqualStrings("2011-11-11", test4.?);
}

pub fn promptCheck(allocator: std.mem.Allocator, message: [:0]const u8) !bool {
    rl.bindKey('\t', rl.insert);
    while (true) {
        const string = try rl.readline(allocator, message);
        defer allocator.free(string);
        if (string.len < 0) continue;
        const r = string[0];
        if (r == 'y' or r == 'Y') {
            return true;
        } else if (r == 'n' or r == 'N') {
            return false;
        }
    }
}

pub fn prompt(allocator: std.mem.Allocator, message: [:0]const u8, empty_ok: bool) ![]const u8 {
    rl.bindKey('\t', rl.insert);
    while (true) {
        const string = try rl.readline(allocator, message);
        defer allocator.free(string);
        if (string.len != 0 or empty_ok) {
            return string;
        }
    }
}

pub fn promptChar(allocator: std.mem.Allocator, message: [:0]const u8) !u8 {
    rl.bindKey('\t', rl.insert);
    while (true) {
        const string = try rl.readline(allocator, message);
        defer allocator.free(string);
        if (string.len == 1)
            return string[0];
    }
}
