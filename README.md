# zilo
kilo editor, ported from C to Zig!

# Why?
I wanted to work on a project in my free time. A while back I watched a few parts of a Video Series in which someone was porting the Kilo Text Editor to Rust. I though that it would be a nice way to learn a new programming language and I also was interested in learning how a simple text editor works. So I decided to do something similiar, and while I didn't want to dive deeper into Rust (yet?), another langauge had caught my eye. I liked Zigs Syntax and its promises of being a "modern" C alternative, so I got started. 

# Build
This program was built with Zig 0.11. Compile it with the command:

```
zig build -Doptimize=ReleaseSafe
```

# Usage

```
./zilo [filepath]
```
