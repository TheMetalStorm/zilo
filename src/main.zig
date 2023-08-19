//import/include
const std = @import("std");
const ascii = std.ascii;
const print = std.debug.print;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("ctype.h");
    @cInclude("sys/ioctl.h");
});

//data
const E = struct{
    var orig_termios: c.termios = undefined; 
    var screenrows: u16 =undefined;
    var screencols: u16 =undefined;
};



//const
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

//input
fn CTRL_KEY(k: u8) u8{
    return (k) & 0x1f;
}

fn editorProcessKeypress() void{
    var ch: u8 = editorReadKey();    
    switch (ch) {
        CTRL_KEY('q') =>{
            print("{s}", .{"\x1b[2J"});
            print("{s}", .{"\x1b[H"});

            c.exit(0);
        },
        else =>{},        
    }
}

//output

fn editorDrawRows() void{
    for (0..E.screenrows)|_| {
        print("{s}", .{"~\r\n"});
    }
}

//terminal


fn getCursorPosition(rows: *u16, cols: *u16) i2{
    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    
    if (c.write(c.STDOUT_FILENO, "\x1b[6n", 4) != 4) return -1;

    while(i<buf.len){
        if (c.read(c.STDIN_FILENO, &buf[i], 1) != 1) break;
        if (buf[i] == 'R') {
            i+= 1;
            break;   
        }
        i+= 1;
    }

    if (buf[0] != '\x1b') return -1;
    if(buf[1] != '[') return -1;

    if (c.sscanf(&buf[2], "%d;%d", rows, cols) != 2) return -1;
    return 0;

}

fn getWindowSize(rows: *u16, cols: *u16) i2{
    var ws : c.winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1) {
        if (c.write(c.STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition(rows, cols);
    } else if ( ws.ws_col == 0){
        if (c.write(c.STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition(rows, cols);
    } 
    else {
        cols.* = ws.ws_col;
        rows.* = ws.ws_row;
        return 0;
  }
  
}

fn editorRefreshScreen() void{
    print("{s}", .{"\x1b[2J"});
    print("{s}", .{"\x1b[H"});
    
    editorDrawRows();
    print("{s}", .{"\x1b[H"});

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
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &E.orig_termios) != 0) {
        die("Failed to restore terminal attributes\nRestart Terminal.");
    }
}

fn enableRawMode() void {
    if (c.tcgetattr(c.STDIN_FILENO, &E.orig_termios) != 0) {
        die("Failed to get terminal attributes");
    }

    _ = c.atexit(disableRawMode);
    var raw: c.termios = E.orig_termios;

    raw.c_iflag &= ~(@as(c_uint, c.BRKINT) | @as(c_uint, c.ICRNL) | @as(c_uint, c.INPCK) | @as(c_uint, c.ISTRIP) | @as(c_uint, c.IXON));
    raw.c_oflag &= ~(@as(c_uint, c.OPOST));
    raw.c_cflag |= (@as(c_uint, c.CS8));
    raw.c_lflag &= ~(@as(c_uint, c.ECHO) | @as(c_uint, c.ICANON) | @as(c_uint, c.IEXTEN) | @as(c_uint, c.ISIG));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    if(c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) == -1) die("tcsetattr")  ;
}

fn die(str: []const u8) void {
    print("{s}", .{"\x1b[2J"});
    print("{s}", .{"\x1b[H"});

    print("{s}\r\n", .{str});
    c.exit(1);
}

//init

pub fn initEditor() void{
    if(getWindowSize(&E.screenrows, &E.screencols) == -1) die("getWindowSize");
}
pub fn main() !void {
    enableRawMode();
    initEditor();
    while (true) {
        editorRefreshScreen();
        editorProcessKeypress();
    }
}
