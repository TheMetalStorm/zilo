const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

fn enableRawMode() !void {
    const stdout = std.io.getStdOut().writer();
    var raw: c.termios = undefined;
    if (c.tcgetattr(c.STDIN_FILENO, &raw) != 0) {
        try stdout.print("Failed to get terminal attributes\n", .{});
        return;
    }

    raw.c_lflag &= @as(c_uint, c.ECHO);
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
}

pub fn main() !void {
    try enableRawMode();

    const stdin = std.io.getStdIn().reader();
    var buf: [100]u8 = undefined;

    if (try stdin.readUntilDelimiterOrEof(&buf, 'q')) |user_input| {
        _ = user_input;
    }
}
