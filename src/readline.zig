const std = @import("std");

pub const CompletionFunc = fn ([*:0]const u8, c_int, c_int) callconv(.c) ?[*:null]?[*:0]u8;
pub const CompentryFunc = fn ([*:0]const u8, c_int) callconv(.c) ?[*:0]u8;
pub const CommandFunc = fn (c_int, c_int) callconv(.c) c_int;

const c = struct {
    extern fn readline(prompt: [*:0]const u8) [*:0]u8;
    extern fn rl_completion_matches([*:0]const u8, ?*const CompentryFunc) ?[*:null]?[*:0]u8;
    extern fn rl_bind_key(c_int, ?*const CommandFunc) c_int;
    extern fn rl_complete(c_int, c_int) c_int;
    extern fn rl_insert(c_int, c_int) c_int;

    extern var rl_attempted_completion_function: ?*const CompletionFunc;
    extern var rl_attempted_completion_over: c_int;
    extern var rl_completion_append_character: c_int;
    extern var rl_completer_word_break_characters: [*:0]const u8;
};

pub fn readline(allocator: std.mem.Allocator, prompt: [:0]const u8) ![]u8 {
    const result = c.readline(prompt);
    defer std.c.free(result);

    return try allocator.dupe(u8, std.mem.span(result));
}

pub fn completionMatches(text: [*:0]const u8, compentry_func: ?*const CompentryFunc) ?[*:null]?[*:0]u8 {
    return c.rl_completion_matches(text, compentry_func);
}

pub fn bindKey(key: i32, function: *const CommandFunc) void {
    std.debug.assert(c.rl_bind_key(key, function) == 0);
}

pub const complete = c.rl_complete;
pub const insert = c.rl_insert;

pub fn setAttemptedCompletionFunction(value: CompletionFunc) void {
    c.rl_attempted_completion_function = value;
}

pub fn setAttemptedCompletionOver(value: i32) void {
    c.rl_attempted_completion_over = value;
}
pub fn setCompletionAppendCharacter(value: i32) void {
    c.rl_completion_append_character = value;
}
pub fn setCompleterWordBreakCharacters(value: [*:0]const u8) void {
    c.rl_completer_word_break_characters = value;
}
