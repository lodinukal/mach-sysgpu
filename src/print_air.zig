const std = @import("std");
const Air = @import("Air.zig");

const indention_size = 2;

pub fn printAir(ir: Air, writer: anytype) !void {
    var p = Printer(@TypeOf(writer)){
        .ir = ir,
        .writer = writer,
        .tty = std.io.tty.Config{ .escape_codes = {} },
    };
    const globals = std.mem.sliceTo(ir.refs[ir.globals_index..], Air.null_index);
    for (globals) |ref| {
        try p.printInst(0, ref);
    }
}

fn Printer(comptime Writer: type) type {
    return struct {
        ir: Air,
        writer: Writer,
        tty: std.io.tty.Config,

        fn printInst(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            switch (inst) {
                .global_variable_decl => {
                    std.debug.assert(indent == 0);
                    try self.printGlobalVariable(indent, index);
                    try self.printFieldEnd();
                },
                .global_const => {
                    std.debug.assert(indent == 0);
                    try self.printConstDecl(indent, index);
                    try self.printFieldEnd();
                },
                .struct_decl => {
                    std.debug.assert(indent == 0);
                    try self.printStructDecl(indent, index);
                    try self.printFieldEnd();
                },
                .fn_decl => {
                    std.debug.assert(indent == 0);
                    try self.printFnDecl(indent, index);
                    try self.printFieldEnd();
                },
                .bool_type,
                .i32_type,
                .u32_type,
                .f32_type,
                .f16_type,
                .sampler_type,
                .comparison_sampler_type,
                .external_texture_type,
                .true,
                .false,
                => {
                    try self.tty.setColor(self.writer, .bright_magenta);
                    try self.writer.print(".{s}", .{@tagName(inst)});
                    try self.tty.setColor(self.writer, .reset);
                },
                .integer, .float => try self.printNumberLiteral(indent, index),
                .mul,
                .div,
                .mod,
                .add,
                .sub,
                .shift_left,
                .shift_right,
                .@"and",
                .@"or",
                .xor,
                .logical_and,
                .logical_or,
                .equal,
                .not_equal,
                .less_than,
                .less_than_equal,
                .greater_than,
                .greater_than_equal,
                .assign,
                => |bin| {
                    try self.instBlockStart(index);
                    try self.printFieldInst(indent + 1, "lhs", bin.lhs);
                    try self.printFieldInst(indent + 1, "rhs", bin.rhs);
                    try self.instBlockEnd(indent);
                },
                .field_access => try self.printFieldAccess(indent, index),
                .index_access => try self.printIndexAccess(indent, index),
                .struct_ref, .var_ref => |ref| {
                    try self.instStart(index);
                    try self.tty.setColor(self.writer, .yellow);
                    try self.writer.print("{d}", .{ref});
                    try self.tty.setColor(self.writer, .reset);
                    try self.instEnd();
                },
                else => {
                    try self.instStart(index);
                    try self.writer.writeAll("TODO");
                    try self.instEnd();
                },
            }
        }

        fn printGlobalVariable(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldString(indent + 1, "name", inst.global_variable_decl.name);
            if (inst.global_variable_decl.addr_space != .none) {
                try self.printFieldEnum(indent + 1, "addr_space", inst.global_variable_decl.addr_space);
            }
            if (inst.global_variable_decl.access_mode != .none) {
                try self.printFieldEnum(indent + 1, "access_mode", inst.global_variable_decl.access_mode);
            }
            if (inst.global_variable_decl.type != Air.null_index) {
                try self.printFieldInst(indent + 1, "type", inst.global_variable_decl.type);
            }
            if (inst.global_variable_decl.expr != Air.null_index) {
                try self.printFieldInst(indent + 1, "value", inst.global_variable_decl.expr);
            }
            try self.instBlockEnd(indent);
        }

        fn printConstDecl(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldString(indent + 1, "name", inst.global_const.name);
            if (inst.global_const.type != Air.null_index) {
                try self.printFieldInst(indent + 1, "type", inst.global_const.type);
            }
            try self.printFieldInst(indent + 1, "value", inst.global_const.expr);
            try self.instBlockEnd(indent);
        }

        fn printStructDecl(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldString(indent + 1, "name", inst.struct_decl.name);
            try self.printFieldName(indent + 1, "members");
            try self.listStart();
            const members = std.mem.sliceTo(self.ir.refs[inst.struct_decl.members..], Air.null_index);
            for (members) |member| {
                const member_index = member;
                const member_inst = self.ir.instructions[member_index];
                try self.printIndent(indent + 2);
                try self.instBlockStart(member_index);
                try self.printFieldString(indent + 3, "name", member_inst.struct_member.name);
                try self.printFieldInst(indent + 3, "type", member_inst.struct_member.type);
                if (member_inst.struct_member.@"align" != 0) {
                    try self.printFieldAny(indent + 3, "align", member_inst.struct_member.@"align");
                }
                if (member_inst.struct_member.size != 0) {
                    try self.printFieldAny(indent + 3, "size", member_inst.struct_member.size);
                }
                try self.instBlockEnd(indent + 2);
                try self.printFieldEnd();
            }
            try self.listEnd(indent + 1);
            try self.printFieldEnd();
            try self.instBlockEnd(indent);
        }

        fn printFnDecl(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldString(indent + 1, "name", inst.fn_decl.name);

            if (inst.fn_decl.params != 0) {
                try self.printFieldName(indent + 1, "params");
                try self.listStart();
                const params = std.mem.sliceTo(self.ir.refs[inst.fn_decl.params..], Air.null_index);
                for (params) |arg| {
                    const arg_index = arg;
                    const arg_inst = self.ir.instructions[arg_index];
                    try self.printIndent(indent + 2);
                    try self.instBlockStart(arg_index);
                    try self.printFieldString(indent + 3, "name", arg_inst.fn_param.name);
                    try self.printFieldInst(indent + 3, "type", arg_inst.fn_param.type);
                    if (arg_inst.fn_param.builtin != .none) {
                        try self.printFieldEnum(indent + 3, "builtin", arg_inst.fn_param.builtin);
                    }
                    if (arg_inst.fn_param.interpolate) |interpolate| {
                        try self.printFieldName(indent + 3, "interpolate");
                        try self.instBlockStart(index);
                        try self.printFieldEnum(indent + 4, "type", interpolate.type);
                        if (interpolate.sample != .none) {
                            try self.printFieldEnum(indent + 4, "sample", interpolate.sample);
                        }
                        try self.instBlockEnd(indent + 4);
                        try self.printFieldEnd();
                    }
                    if (arg_inst.fn_param.location != Air.null_index) {
                        try self.printFieldInst(indent + 3, "location", arg_inst.fn_param.location);
                    }
                    if (arg_inst.fn_param.invariant) {
                        try self.printFieldAny(indent + 3, "invariant", arg_inst.fn_param.invariant);
                    }
                    try self.instBlockEnd(indent + 2);
                    try self.printFieldEnd();
                }
                try self.listEnd(indent + 1);
                try self.printFieldEnd();
            }

            if (inst.fn_decl.statements != 0) {
                try self.printFieldName(indent + 1, "statements");
                try self.listStart();
                const statements = std.mem.sliceTo(self.ir.refs[inst.fn_decl.statements..], Air.null_index);
                for (statements) |statement| {
                    try self.printIndent(indent + 2);
                    try self.printInst(indent + 2, statement);
                    try self.printFieldEnd();
                }
                try self.listEnd(indent + 1);
                try self.printFieldEnd();
            }

            try self.instBlockEnd(indent);
        }

        fn printNumberLiteral(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            switch (inst) {
                inline .integer, .float => |num| {
                    try self.printFieldAny(indent + 1, "value", num.value);
                    try self.printFieldAny(indent + 1, "base", num.base);
                    try self.printFieldEnum(indent + 1, "tag", num.tag);
                },
                else => unreachable,
            }
            try self.instBlockEnd(indent);
        }

        fn printFieldAccess(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldInst(indent + 1, "base", inst.field_access.base);
            try self.printFieldString(indent + 1, "name", inst.field_access.name);
            try self.instBlockEnd(indent);
        }

        fn printIndexAccess(self: @This(), indent: u16, index: Air.InstIndex) Writer.Error!void {
            const inst = self.ir.instructions[index];
            try self.instBlockStart(index);
            try self.printFieldInst(indent + 1, "base", inst.index_access.base);
            try self.printFieldInst(indent + 1, "elem_type", inst.index_access.elem_type);
            try self.printFieldInst(indent + 1, "index", inst.index_access.index);
            try self.instBlockEnd(indent);
        }

        fn instStart(self: @This(), index: Air.InstIndex) !void {
            const inst = self.ir.instructions[index];
            try self.tty.setColor(self.writer, .bold);
            try self.writer.print("{s}", .{@tagName(inst)});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.print("<", .{});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .blue);
            try self.writer.print("{d}", .{index});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.print(">", .{});
            try self.writer.print("(", .{});
            try self.tty.setColor(self.writer, .reset);
        }

        fn instEnd(self: @This()) !void {
            try self.tty.setColor(self.writer, .dim);
            try self.writer.writeAll(")");
            try self.tty.setColor(self.writer, .reset);
        }

        fn instBlockStart(self: @This(), index: Air.InstIndex) !void {
            const inst = self.ir.instructions[index];
            try self.tty.setColor(self.writer, .bold);
            try self.writer.print("{s}", .{@tagName(inst)});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.print("<", .{});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .blue);
            try self.writer.print("{d}", .{index});
            try self.tty.setColor(self.writer, .reset);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.print(">", .{});
            try self.writer.print("(\n", .{});
            try self.tty.setColor(self.writer, .reset);
        }

        fn instBlockEnd(self: @This(), indent: u16) !void {
            try self.printIndent(indent);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.writeAll(")");
            try self.tty.setColor(self.writer, .reset);
        }

        fn listStart(self: @This()) !void {
            try self.tty.setColor(self.writer, .dim);
            try self.writer.writeAll("[\n");
            try self.tty.setColor(self.writer, .reset);
        }

        fn listEnd(self: @This(), indent: u16) !void {
            try self.printIndent(indent);
            try self.tty.setColor(self.writer, .dim);
            try self.writer.writeAll("]");
            try self.tty.setColor(self.writer, .reset);
        }

        fn printFieldName(self: @This(), indent: u16, name: []const u8) !void {
            try self.printIndent(indent);
            try self.tty.setColor(self.writer, .reset);
            try self.writer.print("{s}", .{name});
            try self.tty.setColor(self.writer, .dim);
            try self.writer.print(": ", .{});
            try self.tty.setColor(self.writer, .reset);
        }

        fn printFieldString(self: @This(), indent: u16, name: []const u8, value: u32) !void {
            try self.printFieldName(indent, name);
            try self.tty.setColor(self.writer, .green);
            try self.writer.print("'{s}'", .{self.ir.getStr(value)});
            try self.tty.setColor(self.writer, .reset);
            try self.printFieldEnd();
        }

        fn printFieldInst(self: @This(), indent: u16, name: []const u8, value: Air.InstIndex) !void {
            try self.printFieldName(indent, name);
            try self.printInst(indent, value);
            try self.printFieldEnd();
        }

        fn printFieldEnum(self: @This(), indent: u16, name: []const u8, value: anytype) !void {
            try self.printFieldName(indent, name);
            try self.tty.setColor(self.writer, .magenta);
            try self.writer.print(".{s}", .{@tagName(value)});
            try self.tty.setColor(self.writer, .reset);
            try self.printFieldEnd();
        }

        fn printFieldAny(self: @This(), indent: u16, name: []const u8, value: anytype) !void {
            try self.printFieldName(indent, name);
            try self.tty.setColor(self.writer, .cyan);
            try self.writer.print("{}", .{value});
            try self.tty.setColor(self.writer, .reset);
            try self.printFieldEnd();
        }

        fn printFieldEnd(self: @This()) !void {
            try self.writer.writeAll(",\n");
        }

        fn printIndent(self: @This(), indent: u16) !void {
            try self.writer.writeByteNTimes(' ', indent * indention_size);
        }
    };
}