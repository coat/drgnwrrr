//! Minimal NMOS 6502 interpreter (official opcodes, no decimal mode - the NES 2A03 has none).
//! Used only to run Dragon Warrior routines in isolation for differential tests.
const std = @import("std");

pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xFD,
    pc: u16 = 0,
    c: bool = false,
    z: bool = false,
    i: bool = true,
    d: bool = false,
    v: bool = false,
    n: bool = false,
    mem: *[0x10000]u8,
    /// PRG-ROM is read-only; writes at $8000+ (MMC1 registers) are ignored.
    steps: u64 = 0,

    pub fn rd(self: *Cpu, addr: u16) u8 {
        return self.mem[addr];
    }

    pub fn wr(self: *Cpu, addr: u16, v: u8) void {
        if (addr < 0x8000) self.mem[addr] = v;
    }

    fn rd16zp(self: *Cpu, zp: u8) u16 {
        return @as(u16, self.rd(zp)) | (@as(u16, self.rd(zp +% 1)) << 8);
    }

    fn fetch(self: *Cpu) u8 {
        const v = self.rd(self.pc);
        self.pc +%= 1;
        return v;
    }

    fn fetch16(self: *Cpu) u16 {
        const lo = self.fetch();
        const hi = self.fetch();
        return @as(u16, lo) | (@as(u16, hi) << 8);
    }

    fn push(self: *Cpu, v: u8) void {
        self.mem[0x100 | @as(u16, self.sp)] = v;
        self.sp -%= 1;
    }

    fn pull(self: *Cpu) u8 {
        self.sp +%= 1;
        return self.mem[0x100 | @as(u16, self.sp)];
    }

    fn setZn(self: *Cpu, v: u8) void {
        self.z = v == 0;
        self.n = v & 0x80 != 0;
    }

    fn status(self: *Cpu, b: bool) u8 {
        var p: u8 = 0x20;
        if (self.c) p |= 0x01;
        if (self.z) p |= 0x02;
        if (self.i) p |= 0x04;
        if (self.d) p |= 0x08;
        if (b) p |= 0x10;
        if (self.v) p |= 0x40;
        if (self.n) p |= 0x80;
        return p;
    }

    fn setStatus(self: *Cpu, p: u8) void {
        self.c = p & 0x01 != 0;
        self.z = p & 0x02 != 0;
        self.i = p & 0x04 != 0;
        self.d = p & 0x08 != 0;
        self.v = p & 0x40 != 0;
        self.n = p & 0x80 != 0;
    }

    const Mode = enum { imp, acc, imm, zp, zpx, zpy, abs, abx, aby, ind, izx, izy, rel };

    fn ea(self: *Cpu, mode: Mode) u16 {
        return switch (mode) {
            .zp => self.fetch(),
            .zpx => self.fetch() +% self.x,
            .zpy => self.fetch() +% self.y,
            .abs => self.fetch16(),
            .abx => self.fetch16() +% self.x,
            .aby => self.fetch16() +% self.y,
            .izx => self.rd16zp(self.fetch() +% self.x),
            .izy => self.rd16zp(self.fetch()) +% self.y,
            .ind => blk: {
                const p = self.fetch16();
                const hi_addr = (p & 0xFF00) | ((p +% 1) & 0x00FF); // page-wrap bug
                break :blk @as(u16, self.rd(p)) | (@as(u16, self.rd(hi_addr)) << 8);
            },
            else => unreachable,
        };
    }

    fn operand(self: *Cpu, mode: Mode) u8 {
        return if (mode == .imm) self.fetch() else self.rd(self.ea(mode));
    }

    fn adc(self: *Cpu, m: u8) void {
        const sum = @as(u16, self.a) + m + @intFromBool(self.c);
        const r: u8 = @truncate(sum);
        self.v = (~(self.a ^ m) & (self.a ^ r) & 0x80) != 0;
        self.c = sum > 0xFF;
        self.a = r;
        self.setZn(r);
    }

    fn cmp(self: *Cpu, r: u8, m: u8) void {
        self.c = r >= m;
        self.setZn(r -% m);
    }

    const Rmw = enum { asl, lsr, rol, ror, inc, dec };

    fn rmwVal(self: *Cpu, op: Rmw, v: u8) u8 {
        const r: u8 = switch (op) {
            .asl => blk: {
                self.c = v & 0x80 != 0;
                break :blk v << 1;
            },
            .lsr => blk: {
                self.c = v & 1 != 0;
                break :blk v >> 1;
            },
            .rol => blk: {
                const cin: u8 = @intFromBool(self.c);
                self.c = v & 0x80 != 0;
                break :blk (v << 1) | cin;
            },
            .ror => blk: {
                const cin: u8 = if (self.c) 0x80 else 0;
                self.c = v & 1 != 0;
                break :blk (v >> 1) | cin;
            },
            .inc => v +% 1,
            .dec => v -% 1,
        };
        self.setZn(r);
        return r;
    }

    fn rmw(self: *Cpu, op: Rmw, mode: Mode) void {
        if (mode == .acc) {
            self.a = self.rmwVal(op, self.a);
        } else {
            const addr = self.ea(mode);
            self.wr(addr, self.rmwVal(op, self.rd(addr)));
        }
    }

    fn branch(self: *Cpu, cond: bool) void {
        const off: i8 = @bitCast(self.fetch());
        if (cond) self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% off);
    }

    pub const Error = error{ IllegalOpcode, Brk };

    pub fn step(self: *Cpu) Error!void {
        self.steps += 1;
        const op = self.fetch();
        switch (op) {
            // loads/stores
            0xA9 => self.ld(&self.a, .imm),
            0xA5 => self.ld(&self.a, .zp),
            0xB5 => self.ld(&self.a, .zpx),
            0xAD => self.ld(&self.a, .abs),
            0xBD => self.ld(&self.a, .abx),
            0xB9 => self.ld(&self.a, .aby),
            0xA1 => self.ld(&self.a, .izx),
            0xB1 => self.ld(&self.a, .izy),
            0xA2 => self.ld(&self.x, .imm),
            0xA6 => self.ld(&self.x, .zp),
            0xB6 => self.ld(&self.x, .zpy),
            0xAE => self.ld(&self.x, .abs),
            0xBE => self.ld(&self.x, .aby),
            0xA0 => self.ld(&self.y, .imm),
            0xA4 => self.ld(&self.y, .zp),
            0xB4 => self.ld(&self.y, .zpx),
            0xAC => self.ld(&self.y, .abs),
            0xBC => self.ld(&self.y, .abx),
            0x85 => self.st(self.a, .zp),
            0x95 => self.st(self.a, .zpx),
            0x8D => self.st(self.a, .abs),
            0x9D => self.st(self.a, .abx),
            0x99 => self.st(self.a, .aby),
            0x81 => self.st(self.a, .izx),
            0x91 => self.st(self.a, .izy),
            0x86 => self.st(self.x, .zp),
            0x96 => self.st(self.x, .zpy),
            0x8E => self.st(self.x, .abs),
            0x84 => self.st(self.y, .zp),
            0x94 => self.st(self.y, .zpx),
            0x8C => self.st(self.y, .abs),
            // arithmetic / logic
            0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71 => self.adc(self.operand(aluMode(op))),
            0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1 => self.adc(~self.operand(aluMode(op))),
            0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31 => {
                self.a &= self.operand(aluMode(op));
                self.setZn(self.a);
            },
            0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11 => {
                self.a |= self.operand(aluMode(op));
                self.setZn(self.a);
            },
            0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51 => {
                self.a ^= self.operand(aluMode(op));
                self.setZn(self.a);
            },
            0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1 => self.cmp(self.a, self.operand(aluMode(op))),
            0xE0 => self.cmp(self.x, self.operand(.imm)),
            0xE4 => self.cmp(self.x, self.operand(.zp)),
            0xEC => self.cmp(self.x, self.operand(.abs)),
            0xC0 => self.cmp(self.y, self.operand(.imm)),
            0xC4 => self.cmp(self.y, self.operand(.zp)),
            0xCC => self.cmp(self.y, self.operand(.abs)),
            0x24, 0x2C => {
                const m = self.operand(if (op == 0x24) .zp else .abs);
                self.z = self.a & m == 0;
                self.n = m & 0x80 != 0;
                self.v = m & 0x40 != 0;
            },
            // shifts / inc / dec
            0x0A => self.rmw(.asl, .acc),
            0x06 => self.rmw(.asl, .zp),
            0x16 => self.rmw(.asl, .zpx),
            0x0E => self.rmw(.asl, .abs),
            0x1E => self.rmw(.asl, .abx),
            0x4A => self.rmw(.lsr, .acc),
            0x46 => self.rmw(.lsr, .zp),
            0x56 => self.rmw(.lsr, .zpx),
            0x4E => self.rmw(.lsr, .abs),
            0x5E => self.rmw(.lsr, .abx),
            0x2A => self.rmw(.rol, .acc),
            0x26 => self.rmw(.rol, .zp),
            0x36 => self.rmw(.rol, .zpx),
            0x2E => self.rmw(.rol, .abs),
            0x3E => self.rmw(.rol, .abx),
            0x6A => self.rmw(.ror, .acc),
            0x66 => self.rmw(.ror, .zp),
            0x76 => self.rmw(.ror, .zpx),
            0x6E => self.rmw(.ror, .abs),
            0x7E => self.rmw(.ror, .abx),
            0xE6 => self.rmw(.inc, .zp),
            0xF6 => self.rmw(.inc, .zpx),
            0xEE => self.rmw(.inc, .abs),
            0xFE => self.rmw(.inc, .abx),
            0xC6 => self.rmw(.dec, .zp),
            0xD6 => self.rmw(.dec, .zpx),
            0xCE => self.rmw(.dec, .abs),
            0xDE => self.rmw(.dec, .abx),
            0xE8 => {
                self.x +%= 1;
                self.setZn(self.x);
            },
            0xC8 => {
                self.y +%= 1;
                self.setZn(self.y);
            },
            0xCA => {
                self.x -%= 1;
                self.setZn(self.x);
            },
            0x88 => {
                self.y -%= 1;
                self.setZn(self.y);
            },
            // transfers
            0xAA => self.tr(&self.x, self.a),
            0xA8 => self.tr(&self.y, self.a),
            0x8A => self.tr(&self.a, self.x),
            0x98 => self.tr(&self.a, self.y),
            0xBA => self.tr(&self.x, self.sp),
            0x9A => self.sp = self.x,
            // stack
            0x48 => self.push(self.a),
            0x68 => {
                self.a = self.pull();
                self.setZn(self.a);
            },
            0x08 => self.push(self.status(true)),
            0x28 => self.setStatus(self.pull()),
            // flags
            0x18 => self.c = false,
            0x38 => self.c = true,
            0x58 => self.i = false,
            0x78 => self.i = true,
            0xD8 => self.d = false,
            0xF8 => self.d = true,
            0xB8 => self.v = false,
            // control flow
            0x4C => self.pc = self.fetch16(),
            0x6C => self.pc = self.ea(.ind),
            0x20 => {
                const target = self.fetch16();
                const ret = self.pc -% 1;
                self.push(@truncate(ret >> 8));
                self.push(@truncate(ret));
                self.pc = target;
            },
            0x60 => {
                const lo = self.pull();
                const hi = self.pull();
                self.pc = (@as(u16, lo) | (@as(u16, hi) << 8)) +% 1;
            },
            0x40 => {
                self.setStatus(self.pull());
                const lo = self.pull();
                const hi = self.pull();
                self.pc = @as(u16, lo) | (@as(u16, hi) << 8);
            },
            0x10 => self.branch(!self.n),
            0x30 => self.branch(self.n),
            0x50 => self.branch(!self.v),
            0x70 => self.branch(self.v),
            0x90 => self.branch(!self.c),
            0xB0 => self.branch(self.c),
            0xD0 => self.branch(!self.z),
            0xF0 => self.branch(self.z),
            0xEA => {},
            0x00 => return error.Brk,
            else => return error.IllegalOpcode,
        }
    }

    fn aluMode(op: u8) Mode {
        return switch (op & 0x1F) {
            0x09 => .imm,
            0x05 => .zp,
            0x15 => .zpx,
            0x0D => .abs,
            0x1D => .abx,
            0x19 => .aby,
            0x01 => .izx,
            0x11 => .izy,
            else => unreachable,
        };
    }

    fn ld(self: *Cpu, reg: *u8, mode: Mode) void {
        reg.* = self.operand(mode);
        self.setZn(reg.*);
    }

    fn st(self: *Cpu, v: u8, mode: Mode) void {
        self.wr(self.ea(mode), v);
    }

    fn tr(self: *Cpu, dst: *u8, v: u8) void {
        dst.* = v;
        self.setZn(v);
    }
};
