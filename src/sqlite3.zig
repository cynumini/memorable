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
    extern fn sqlite3_bind_text(*Statement, c_int, [*]const u8, c_int, DestructorTypeFunc) c_int;
    extern fn sqlite3_bind_int(?*Statement, c_int, c_int) c_int;
    extern fn sqlite3_bind_int64(?*Statement, c_int, i64) c_int;
    extern fn sqlite3_bind_null(?*Statement, c_int) c_int;
    extern fn sqlite3_column_int(*Statement, iCol: c_int) c_int;
    extern fn sqlite3_column_int64(?*Statement, iCol: c_int) i64;
    extern fn sqlite3_column_text(*Statement, iCol: c_int) ?[*:0]const u8;
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
            unreachable;
        }
    }
    pub fn execOne(self: *SQLite3, sql: [:0]const u8, args: anytype) void {
        const statement = self.prepare(sql);
        defer statement.finalize();
        inline for (args, 0..) |arg, i| {
            statement.bind(i + 1, arg);
        }
        var code = statement.step();
        var warn: bool = false;
        while (code != .done) {
            std.debug.assert(code == .busy);
            if (!warn) {
                std.log.warn("Database is busy.", .{});
                warn = true;
            }
            code = statement.step();
        }
    }

    pub fn fetchOne(self: *SQLite3, T: type, sql: [:0]const u8, args: anytype) T {
        const statement = self.prepare(sql);
        defer statement.finalize();
        inline for (args, 0..) |arg, i| {
            statement.bind(i + 1, arg);
        }
        std.debug.assert(statement.step() == .row);
        const version = statement.column(T, 0);
        std.debug.assert(statement.step() == .done);
        return version;
    }

    pub fn fetchOne2(self: *SQLite3, allocator: std.mem.Allocator, T: type, sql: [:0]const u8, args: anytype) !?T {
        var element: ?T = null;
        const statement = self.prepare(sql);
        defer statement.finalize();
        inline for (args, 0..) |arg, i| {
            statement.bind(i + 1, arg);
        }
        var code = statement.step();
        if (code == .row) {
            element = undefined;
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                if (field.type == []const u8) {
                    @field(element.?, field.name) = try allocator.dupe(
                        u8,
                        statement.column(field.type, i),
                    );
                } else if (field.type == ?[]const u8) {
                    if (statement.column(field.type, i)) |value| {
                        @field(element.?, field.name) = try allocator.dupe(u8, value);
                    } else {
                        @field(element.?, field.name) = null;
                    }
                } else {
                    @field(element.?, field.name) = statement.column(field.type, i);
                }
            }
            code = statement.step();
        }
        std.debug.assert(code == .done);
        return element;
    }

    pub fn fetchMany(self: *SQLite3, gpa: std.mem.Allocator, T: type, sql: [:0]const u8, args: anytype) !std.ArrayList(T) {
        var array: std.ArrayList(T) = .empty;
        const statement = self.prepare(sql);
        defer statement.finalize();
        inline for (args, 0..) |arg, i| {
            statement.bind(i + 1, arg);
        }
        var code = statement.step();
        while (code != .done) : (code = statement.step()) {
            std.debug.assert(code == .row);
            var element: T = undefined;
            inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
                if (field.type == []const u8) {
                    @field(element, field.name) = try gpa.dupe(u8, statement.column(field.type, i));
                } else if (field.type == ?[]const u8) {
                    if (statement.column(field.type, i)) |value| {
                        @field(element, field.name) = try gpa.dupe(u8, value);
                    } else {
                        @field(element, field.name) = null;
                    }
                } else {
                    @field(element, field.name) = statement.column(field.type, i);
                }
            }
            try array.append(gpa, element);
        }
        return array;
    }
};

pub const Statement = opaque {
    pub fn finalize(self: *Statement) void {
        std.debug.assert(ResultCode.init(c.sqlite3_finalize(self)) == .ok);
    }

    pub fn step(self: *Statement) ResultCode {
        return @enumFromInt(c.sqlite3_step(self));
    }

    pub fn bind(self: *Statement, index: usize, value: anytype) void {
        const kind = @TypeOf(value);
        switch (kind) {
            []const u8 => self.bindText(index, value, .static),
            bool => self.bindInt(index, @intFromBool(value)),
            i32, comptime_int => self.bindInt(index, value),
            usize, u32 => self.bindInt64(index, @intCast(value)),
            else => {
                switch (@typeInfo(kind)) {
                    .optional => {
                        if (value) |v| {
                            self.bind(index, v);
                        } else {
                            self.bindNull(index);
                        }
                    },
                    .@"enum" => self.bindInt(index, @intFromEnum(value)),
                    else => {
                        std.debug.print("type \"{}\" is not implemented for bind!\n", .{kind});
                        unreachable;
                    },
                }
            },
        }
    }

    pub fn bindNull(self: *Statement, index: usize) void {
        std.debug.assert(ResultCode.init(c.sqlite3_bind_null(self, @intCast(index))) == .ok);
    }

    pub fn bindText(self: *Statement, index: usize, value: []const u8, destructor_type: DestructorType) void {
        const dt = switch (destructor_type) {
            .static => SQLITE_STATIC,
            .transient => SQLITE_TRANSIENT,
        };
        std.debug.assert(ResultCode.init(c.sqlite3_bind_text(self, @intCast(index), value.ptr, @intCast(value.len), dt)) == .ok);
    }

    pub fn bindInt(self: *Statement, index: usize, value: i32) void {
        std.debug.assert(ResultCode.init(c.sqlite3_bind_int(self, @intCast(index), value)) == .ok);
    }
    pub fn bindInt64(self: *Statement, index: usize, value: i64) void {
        std.debug.assert(ResultCode.init(c.sqlite3_bind_int64(self, @intCast(index), value)) == .ok);
    }

    pub fn column(self: *Statement, T: type, index: usize) T {
        return blk: switch (T) {
            i32 => c.sqlite3_column_int(self, @intCast(index)),
            u32 => @intCast(c.sqlite3_column_int(self, @intCast(index))),
            usize => @intCast(c.sqlite3_column_int64(self, @intCast(index))),
            [:0]const u8 => std.mem.span(c.sqlite3_column_text(self, @intCast(index)).?),
            []const u8 => std.mem.span(c.sqlite3_column_text(self, @intCast(index)).?),
            ?[]const u8 => {
                if (c.sqlite3_column_text(self, @intCast(index))) |text| {
                    break :blk std.mem.span(text);
                }
                break :blk null;
            },

            else => switch (@typeInfo(T)) {
                .@"enum" => @as(T, @enumFromInt(c.sqlite3_column_int(self, @intCast(index)))),
                else => {
                    std.debug.print("type \"{}\" is not implemented for column!\n", .{T});
                    unreachable;
                },
            },
        };
    }

    pub fn reset(self: *Statement) void {
        std.debug.assert(ResultCode.init(c.sqlite3_reset(self)) == .ok);
    }
};

const ResultCode = enum(c_int) {
    ok = 0,
    busy = 5,
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
