//import/include
const std = @import("std");
const ascii = std.ascii;
const print = std.debug.print;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
});

//data
var orig_termios: c.termios = undefined;


//const
const stdin = std.io.getStdIn().reader();




//terminal

fn CTRL_KEY(k: u8) u8{
    return (k) & 0x1f;
}

fn editorProcessKeypress() void{
    var ch: u8 = editorReadKey();    
    switch (ch) {
        CTRL_KEY('q') =>{
            c.exit(0);
        },
        else =>{},        
    }
}

fn editorReadKey() u8{
    var readChar: u8 = undefined;
    if(stdin.readByte()) |res|{
        readChar = res;
    }
    else |err| {
        if(err == error.EndOfStream) {
            readChar = 0;
        }
        else {
            die("read");
        }
    }
    return readChar;
}

fn disableRawMode() callconv(.C) void {
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &orig_termios) != 0) {
        die("Failed to restore terminal attributes\nRestart Terminal.");
    }
}

fn enableRawMode() void {
    if (c.tcgetattr(c.STDIN_FILENO, &orig_termios) != 0) {
        die("Failed to get terminal attributes");
    }

    _ = c.atexit(disableRawMode);
    var raw: c.termios = orig_termios;

    raw.c_iflag &= ~(@as(c_uint, c.BRKINT) | @as(c_uint, c.ICRNL) | @as(c_uint, c.INPCK) | @as(c_uint, c.ISTRIP) | @as(c_uint, c.IXON));
    raw.c_oflag &= ~(@as(c_uint, c.OPOST));
    raw.c_cflag |= (@as(c_uint, c.CS8));
    raw.c_lflag &= ~(@as(c_uint, c.ECHO) | @as(c_uint, c.ICANON) | @as(c_uint, c.IEXTEN) | @as(c_uint, c.ISIG));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    if(c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) == -1) die("tcsetattr")  ;
}

fn die(str: []const u8) void {
    print("{s}\r\n", .{str});
    c.exit(1);
}

//init
pub fn main() !void {
    enableRawMode();

    while (true) {
        editorProcessKeypress();
    }
}
