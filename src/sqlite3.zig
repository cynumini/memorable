const std = @import("std");
pub const __helpers = std.zig.c_translation.helpers;

pub const ExecCallback = *const fn (?*anyopaque, c_int, [*][*:0]u8, [*][*:0]u8) callconv(.c) c_int;
const DestructorTypeFunc = ?*const fn (?*anyopaque) callconv(.c) void;
const DestructorType = enum { static, transient };

pub const SQLITE_STATIC = __helpers.cast(DestructorTypeFunc, @as(c_int, 0));
pub const SQLITE_TRANSIENT = __helpers.cast(DestructorTypeFunc, -@as(c_int, 1));

const c = struct {
    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: **SQLite3) c_int;
    extern fn sqlite3_close(*SQLite3) c_int;
    extern fn sqlite3_prepare_v2(
        db: *SQLite3,
        zSql: [*:0]const u8,
        nByte: c_int,
        ppStmt: **Statement,
        pzTail: ?*[*:0]const u8,
    ) c_int;
    extern fn sqlite3_finalize(pStmt: *Statement) c_int;
    extern fn sqlite3_step(*Statement) c_int;
    extern fn sqlite3_bind_text(*Statement, c_int, [*:0]const u8, c_int, DestructorTypeFunc) c_int;
    extern fn sqlite3_column_int(*Statement, iCol: c_int) c_int;
    extern fn sqlite3_column_text(*Statement, iCol: c_int) [*:0]const u8;
    extern fn sqlite3_exec(*SQLite3, sql: [*:0]const u8, callback: ?ExecCallback, ?*anyopaque, errmsg: *[*:0]u8) c_int;
    extern fn sqlite3_reset(pStmt: ?*Statement) c_int;
};

pub const SQLite3 = opaque {
    pub fn close(self: *SQLite3) void {
        std.debug.assert(ResultCode.init(c.sqlite3_close(self)) == .ok);
    }

    pub fn prepare(self: *SQLite3, sql: [:0]const u8) *Statement {
        var statement: *Statement = undefined;
        std.debug.assert(ResultCode.init(c.sqlite3_prepare_v2(
            self,
            sql,
            @intCast(sql.len),
            &statement,
            null,
        )) == .ok);
        return statement;
    }

    pub fn exec(self: *SQLite3, sql: [:0]const u8, callback: ?ExecCallback, user_data: ?*anyopaque) void {
        var errmsg: [*:0]u8 = undefined;
        if (ResultCode.init(c.sqlite3_exec(self, sql, callback, user_data, &errmsg)) != .ok) {
            std.debug.print("{s}\n", .{errmsg});
            unreachable;
        }
    }

    pub fn fetchOne(self: *SQLite3, T: type, sql: [:0]const u8) T {
        const statement = self.prepare(sql);
        defer statement.finalize();
        std.debug.assert(statement.step() == .row);
        const version = statement.column(T, 0);
        std.debug.assert(statement.step() == .done);
        return version;
    }
};

pub const Statement = opaque {
    pub fn finalize(self: *Statement) void {
        std.debug.assert(ResultCode.init(c.sqlite3_finalize(self)) == .ok);
    }

    pub fn step(self: *Statement) ResultCode {
        return @enumFromInt(c.sqlite3_step(self));
    }

    pub fn bindText(self: *Statement, index: usize, value: [:0]const u8, destructor_type: DestructorType) void {
        const dt = switch (destructor_type) {
            .static => SQLITE_STATIC,
            .transient => SQLITE_TRANSIENT,
        };
        std.debug.assert(ResultCode.init(c.sqlite3_bind_text(self, @intCast(index), value, @intCast(value.len), dt)) == .ok);
    }
    pub fn column(self: *Statement, T: type, index: usize) T {
        return switch (T) {
            i32 => c.sqlite3_column_int(self, @intCast(index)),
            [:0]const u8 => std.mem.span(c.sqlite3_column_text(self, @intCast(index))),
            []const u8 => std.mem.span(c.sqlite3_column_text(self, @intCast(index))),
            else => unreachable,
        };
    }

    pub fn reset(self: *Statement) void {
        std.debug.assert(ResultCode.init(c.sqlite3_reset(self)) == .ok);
    }
};

const ResultCode = enum(c_int) {
    ok = 0,
    row = 100,
    done = 101,

    fn init(self: c_int) ResultCode {
        return @enumFromInt(self);
    }
};

pub fn open(filename: [:0]const u8) *SQLite3 {
    var sqlite3: *SQLite3 = undefined;
    std.debug.assert(ResultCode.init(c.sqlite3_open(filename, &sqlite3)) == .ok);
    return sqlite3;
}
