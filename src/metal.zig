const std = @import("std");
const ca = @import("objc").quartz_core.ca;
const mtl = @import("objc").metal.mtl;
const ns = @import("objc").foundation.ns;
const dgpu = @import("dgpu/main.zig");
const utils = @import("utils.zig");
const shader = @import("shader.zig");
const conv = @import("metal/conv.zig");

const log = std.log.scoped(.metal);
const max_storage_buffers_per_shader_stage = 8;
const max_uniform_buffers_per_shader_stage = 12;
const max_vertex_buffers = 8;
const slot_vertex_buffers = 20;
const slot_buffer_lengths = 28;

var allocator: std.mem.Allocator = undefined;

pub const InitOptions = struct {};

pub fn init(alloc: std.mem.Allocator, options: InitOptions) !void {
    _ = options;
    allocator = alloc;
}

fn isDepthFormat(format: mtl.PixelFormat) bool {
    return switch (format) {
        mtl.PixelFormatDepth16Unorm => true,
        mtl.PixelFormatDepth24Unorm_Stencil8 => true,
        mtl.PixelFormatDepth32Float => true,
        mtl.PixelFormatDepth32Float_Stencil8 => true,
        else => false,
    };
}

fn isStencilFormat(format: mtl.PixelFormat) bool {
    return switch (format) {
        mtl.PixelFormatStencil8 => true,
        mtl.PixelFormatDepth24Unorm_Stencil8 => true,
        mtl.PixelFormatDepth32Float_Stencil8 => true,
        else => false,
    };
}

fn entrypointString(name: [*:0]const u8) [*:0]const u8 {
    return if (std.mem.eql(u8, std.mem.span(name), "main")) "main_" else name;
}

fn entrypointSlice(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "main")) "main_" else name;
}

pub const Instance = struct {
    manager: utils.Manager(Instance) = .{},

    pub fn init(desc: *const dgpu.Instance.Descriptor) !*Instance {
        // TODO
        _ = desc;

        ns.init();
        ca.init();
        mtl.init();

        var instance = try allocator.create(Instance);
        instance.* = .{};
        return instance;
    }

    pub fn deinit(instance: *Instance) void {
        allocator.destroy(instance);
    }

    pub fn createSurface(instance: *Instance, desc: *const dgpu.Surface.Descriptor) !*Surface {
        return Surface.init(instance, desc);
    }
};

pub const Adapter = struct {
    manager: utils.Manager(Adapter) = .{},
    mtl_device: *mtl.Device,

    pub fn init(instance: *Instance, options: *const dgpu.RequestAdapterOptions) !*Adapter {
        _ = instance;
        _ = options;

        // TODO - choose appropriate device from options
        const mtl_device = mtl.createSystemDefaultDevice() orelse {
            return error.NoAdapterFound;
        };

        var adapter = try allocator.create(Adapter);
        adapter.* = .{ .mtl_device = mtl_device };
        return adapter;
    }

    pub fn deinit(adapter: *Adapter) void {
        adapter.mtl_device.release();
        allocator.destroy(adapter);
    }

    pub fn createDevice(adapter: *Adapter, desc: ?*const dgpu.Device.Descriptor) !*Device {
        return Device.init(adapter, desc);
    }

    pub fn getProperties(adapter: *Adapter) dgpu.Adapter.Properties {
        const mtl_device = adapter.mtl_device;
        return .{
            .vendor_id = 0, // TODO
            .vendor_name = "", // TODO
            .architecture = "", // TODO
            .device_id = 0, // TODO
            .name = mtl_device.name().utf8String(),
            .driver_description = "", // TODO
            .adapter_type = if (mtl_device.isLowPower()) .integrated_gpu else .discrete_gpu,
            .backend_type = .metal,
            .compatibility_mode = .false,
        };
    }
};

pub const Surface = struct {
    manager: utils.Manager(Surface) = .{},
    layer: *ca.MetalLayer,

    pub fn init(instance: *Instance, desc: *const dgpu.Surface.Descriptor) !*Surface {
        _ = instance;

        if (utils.findChained(dgpu.Surface.DescriptorFromMetalLayer, desc.next_in_chain.generic)) |mtl_desc| {
            var surface = try allocator.create(Surface);
            surface.* = .{ .layer = @ptrCast(mtl_desc.layer) };
            return surface;
        } else {
            return error.InvalidDescriptor;
        }
    }

    pub fn deinit(surface: *Surface) void {
        allocator.destroy(surface);
    }
};

pub const Device = struct {
    const MapAsyncCallback = struct {
        callback: dgpu.Buffer.MapCallback,
        userdata: ?*anyopaque,
        fence_value: u64,
    };

    manager: utils.Manager(Device) = .{},
    mtl_device: *mtl.Device,
    queue: ?*Queue = null,
    lost_cb: ?dgpu.Device.LostCallback = null,
    lost_cb_userdata: ?*anyopaque = null,
    log_cb: ?dgpu.LoggingCallback = null,
    log_cb_userdata: ?*anyopaque = null,
    err_cb: ?dgpu.ErrorCallback = null,
    err_cb_userdata: ?*anyopaque = null,
    map_async_callbacks: std.ArrayList(MapAsyncCallback),

    pub fn init(adapter: *Adapter, desc: ?*const dgpu.Device.Descriptor) !*Device {
        // TODO
        _ = desc;

        var device = try allocator.create(Device);
        device.* = .{
            .mtl_device = adapter.mtl_device,
            .map_async_callbacks = std.ArrayList(MapAsyncCallback).init(allocator),
        };
        return device;
    }

    pub fn deinit(device: *Device) void {
        if (device.lost_cb) |lost_cb| {
            lost_cb(.destroyed, "Device was destroyed.", device.lost_cb_userdata);
        }

        device.map_async_callbacks.deinit();
        if (device.queue) |queue| queue.manager.release();
        allocator.destroy(device);
    }

    pub fn createBindGroup(device: *Device, desc: *const dgpu.BindGroup.Descriptor) !*BindGroup {
        return BindGroup.init(device, desc);
    }

    pub fn createBindGroupLayout(device: *Device, desc: *const dgpu.BindGroupLayout.Descriptor) !*BindGroupLayout {
        return BindGroupLayout.init(device, desc);
    }

    pub fn createBuffer(device: *Device, desc: *const dgpu.Buffer.Descriptor) !*Buffer {
        return Buffer.init(device, desc);
    }

    pub fn createCommandEncoder(device: *Device, desc: *const dgpu.CommandEncoder.Descriptor) !*CommandEncoder {
        return CommandEncoder.init(device, desc);
    }

    pub fn createComputePipeline(device: *Device, desc: *const dgpu.ComputePipeline.Descriptor) !*ComputePipeline {
        return ComputePipeline.init(device, desc);
    }

    pub fn createPipelineLayout(device: *Device, desc: *const dgpu.PipelineLayout.Descriptor) !*PipelineLayout {
        return PipelineLayout.init(device, desc);
    }

    pub fn createRenderPipeline(device: *Device, desc: *const dgpu.RenderPipeline.Descriptor) !*RenderPipeline {
        return RenderPipeline.init(device, desc);
    }

    pub fn createShaderModuleAir(device: *Device, air: *const shader.Air) !*ShaderModule {
        return ShaderModule.initAir(device, air);
    }

    pub fn createShaderModuleSpirv(device: *Device, code: []const u8) !*ShaderModule {
        _ = code;
        _ = device;
        return error.unsupported;
    }

    pub fn createSwapChain(device: *Device, surface: *Surface, desc: *const dgpu.SwapChain.Descriptor) !*SwapChain {
        return SwapChain.init(device, surface, desc);
    }

    pub fn createTexture(device: *Device, desc: *const dgpu.Texture.Descriptor) !*Texture {
        return Texture.init(device, desc);
    }

    pub fn getQueue(device: *Device) !*Queue {
        if (device.queue == null) {
            device.queue = try Queue.init(device);
        }
        return device.queue.?;
    }

    pub fn tick(device: *Device) !void {
        const queue = try device.getQueue();

        var i: usize = 0;
        while (i < device.map_async_callbacks.items.len) {
            const map_async_callback = device.map_async_callbacks.items[i];
            const completed_value = queue.completed_value;

            if (map_async_callback.fence_value <= completed_value) {
                map_async_callback.callback(.success, map_async_callback.userdata);
                _ = device.map_async_callbacks.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

pub const SwapChain = struct {
    manager: utils.Manager(SwapChain) = .{},
    device: *Device,
    surface: *Surface,
    current_drawable: ?*ca.MetalDrawable = null,

    pub fn init(device: *Device, surface: *Surface, desc: *const dgpu.SwapChain.Descriptor) !*SwapChain {
        // TODO
        _ = desc;

        surface.layer.setDevice(device.mtl_device);

        var swapchain = try allocator.create(SwapChain);
        swapchain.* = .{ .device = device, .surface = surface };
        return swapchain;
    }

    pub fn deinit(swapchain: *SwapChain) void {
        allocator.destroy(swapchain);
    }

    pub fn getCurrentTextureView(swapchain: *SwapChain) !*TextureView {
        swapchain.current_drawable = swapchain.surface.layer.nextDrawable();
        if (swapchain.current_drawable) |drawable| {
            return TextureView.initFromMtlTexture(drawable.texture().retain());
        } else {
            // TODO - handle no drawable
            unreachable;
        }
    }

    pub fn present(swapchain: *SwapChain) !void {
        if (swapchain.current_drawable) |_| {
            const queue = try swapchain.device.getQueue();
            const command_buffer = queue.command_queue.commandBuffer() orelse {
                return error.newCommandBufferFailed;
            };
            command_buffer.presentDrawable(@ptrCast(swapchain.current_drawable)); // TODO - objc casting?
            command_buffer.commit();
        }
    }
};

pub const Buffer = struct {
    manager: utils.Manager(Buffer) = .{},
    device: *Device,
    mtl_buffer: *mtl.Buffer,
    last_used_fence_value: u64 = 0,

    pub fn init(device: *Device, desc: *const dgpu.Buffer.Descriptor) !*Buffer {
        const mtl_device = device.mtl_device;

        const mtl_buffer = mtl_device.newBufferWithLength_options(
            desc.size,
            conv.metalResourceOptionsForBuffer(desc.usage),
        ) orelse {
            return error.newBufferFailed;
        };
        if (desc.label) |label| {
            mtl_buffer.setLabel(ns.String.stringWithUTF8String(label));
        }

        var buffer = try allocator.create(Buffer);
        buffer.* = .{
            .device = device,
            .mtl_buffer = mtl_buffer,
        };
        return buffer;
    }

    pub fn deinit(buffer: *Buffer) void {
        buffer.mtl_buffer.release();
        allocator.destroy(buffer);
    }

    pub fn getConstMappedRange(buffer: *Buffer, offset: usize, size: usize) !*anyopaque {
        _ = size;
        const mtl_buffer = buffer.mtl_buffer;
        const base: [*]const u8 = @ptrCast(mtl_buffer.contents());
        return @constCast(base + offset);
    }

    pub fn mapAsync(buffer: *Buffer, mode: dgpu.MapModeFlags, offset: usize, size: usize, callback: dgpu.Buffer.MapCallback, userdata: ?*anyopaque) !void {
        _ = size;
        _ = offset;
        _ = mode;

        const device = buffer.device;
        try device.map_async_callbacks.append(.{
            .callback = callback,
            .userdata = userdata,
            .fence_value = buffer.last_used_fence_value,
        });
    }

    pub fn unmap(buffer: *Buffer) !void {
        _ = buffer;
    }
};

pub const Texture = struct {
    manager: utils.Manager(Texture) = .{},
    mtl_texture: *mtl.Texture,

    pub fn init(device: *Device, desc: *const dgpu.Texture.Descriptor) !*Texture {
        const mtl_device = device.mtl_device;

        var mtl_desc = mtl.TextureDescriptor.alloc().init();
        mtl_desc.setTextureType(conv.metalTextureType(desc.dimension, desc.size, desc.sample_count));
        mtl_desc.setPixelFormat(conv.metalPixelFormat(desc.format));
        mtl_desc.setWidth(desc.size.width);
        mtl_desc.setHeight(desc.size.height);
        mtl_desc.setDepth(if (desc.dimension == .dimension_3d) desc.size.depth_or_array_layers else 1);
        mtl_desc.setMipmapLevelCount(desc.mip_level_count);
        mtl_desc.setSampleCount(desc.sample_count);
        mtl_desc.setArrayLength(if (desc.dimension == .dimension_3d) 1 else desc.size.depth_or_array_layers);
        mtl_desc.setStorageMode(conv.metalStorageModeForTexture(desc.usage));
        mtl_desc.setUsage(conv.metalTextureUsage(desc.usage, desc.view_format_count));

        const mtl_texture = mtl_device.newTextureWithDescriptor(mtl_desc) orelse {
            return error.newTextureFailed;
        };
        if (desc.label) |label| {
            mtl_texture.setLabel(ns.String.stringWithUTF8String(label));
        }

        var texture = try allocator.create(Texture);
        texture.* = .{
            .mtl_texture = mtl_texture,
        };
        return texture;
    }

    pub fn deinit(texture: *Texture) void {
        texture.mtl_texture.release();
        allocator.destroy(texture);
    }

    pub fn createView(texture: *Texture, desc: ?*const dgpu.TextureView.Descriptor) !*TextureView {
        return TextureView.init(texture, desc);
    }
};

pub const TextureView = struct {
    manager: utils.Manager(TextureView) = .{},
    mtl_texture: *mtl.Texture,

    pub fn init(texture: *Texture, opt_desc: ?*const dgpu.TextureView.Descriptor) !*TextureView {
        var mtl_texture = texture.mtl_texture;
        if (opt_desc) |desc| {
            // TODO - analyze desc to see if we need to create a new view

            mtl_texture = mtl_texture.newTextureViewWithPixelFormat_textureType_levels_slices(
                conv.metalPixelFormatForView(desc.format, mtl_texture.pixelFormat(), desc.aspect),
                conv.metalTextureTypeForView(desc.dimension),
                ns.Range.init(desc.base_mip_level, desc.mip_level_count),
                ns.Range.init(desc.base_array_layer, desc.array_layer_count),
            ) orelse {
                return error.newTextureViewFailed;
            };
            if (desc.label) |label| {
                mtl_texture.setLabel(ns.String.stringWithUTF8String(label));
            }
        }

        var view = try allocator.create(TextureView);
        view.* = .{
            .mtl_texture = mtl_texture,
        };
        return view;
    }

    pub fn initFromMtlTexture(mtl_texture: *mtl.Texture) !*TextureView {
        var view = try allocator.create(TextureView);
        view.* = .{
            .mtl_texture = mtl_texture,
        };
        return view;
    }

    pub fn deinit(view: *TextureView) void {
        view.mtl_texture.release();
        allocator.destroy(view);
    }
};

pub const Sampler = struct {
    manager: utils.Manager(TextureView) = .{},
    mtl_sampler: *mtl.SamplerState,
};

pub const BindGroupLayout = struct {
    manager: utils.Manager(BindGroupLayout) = .{},

    pub fn init(device: *Device, descriptor: *const dgpu.BindGroupLayout.Descriptor) !*BindGroupLayout {
        _ = descriptor;
        _ = device;

        var layout = try allocator.create(BindGroupLayout);
        layout.* = .{};
        return layout;
    }

    pub fn initDefault() !*BindGroupLayout {
        var layout = try allocator.create(BindGroupLayout);
        layout.* = .{};
        return layout;
    }

    pub fn deinit(layout: *BindGroupLayout) void {
        allocator.destroy(layout);
    }
};

pub const BindGroup = struct {
    const Kind = enum {
        buffer,
        sampler,
        texture,
    };

    const Entry = struct {
        kind: Kind,
        binding: u32,
        buffer: ?*Buffer = null,
        offset: u32 = 0,
        size: u32,
        sampler: ?*mtl.SamplerState = null,
        texture: ?*mtl.Texture = null,
    };

    manager: utils.Manager(BindGroup) = .{},
    entries: []const Entry,

    pub fn init(device: *Device, desc: *const dgpu.BindGroup.Descriptor) !*BindGroup {
        _ = device;

        var mtl_entries = try allocator.alloc(Entry, desc.entry_count);
        errdefer allocator.free(mtl_entries);

        for (desc.entries.?[0..desc.entry_count], 0..) |entry, i| {
            var mtl_entry = &mtl_entries[i];
            // TODO - need to remap user binding space [0, 1000) to API binding space
            mtl_entry.binding = entry.binding;
            if (entry.buffer) |buffer_raw| {
                const buffer: *Buffer = @ptrCast(@alignCast(buffer_raw));
                mtl_entry.kind = .buffer;
                mtl_entry.buffer = buffer;
                mtl_entry.offset = @intCast(entry.offset);
                mtl_entry.size = @intCast(entry.size);
            } else if (entry.sampler) |sampler_raw| {
                const sampler: *Sampler = @ptrCast(@alignCast(sampler_raw));
                mtl_entry.kind = .sampler;
                mtl_entry.sampler = sampler.mtl_sampler;
            } else if (entry.texture_view) |texture_view_raw| {
                const texture_view: *TextureView = @ptrCast(@alignCast(texture_view_raw));
                mtl_entry.kind = .texture;
                mtl_entry.texture = texture_view.mtl_texture;
            }
        }

        var group = try allocator.create(BindGroup);
        group.* = .{ .entries = mtl_entries };
        return group;
    }

    pub fn deinit(group: *BindGroup) void {
        allocator.free(group.entries);
        allocator.destroy(group);
    }
};

pub const PipelineLayout = struct {
    manager: utils.Manager(PipelineLayout) = .{},

    pub fn init(device: *Device, desc: *const dgpu.PipelineLayout.Descriptor) !*PipelineLayout {
        _ = desc;
        _ = device;

        var layout = try allocator.create(PipelineLayout);
        layout.* = .{};
        return layout;
    }

    pub fn deinit(layout: *PipelineLayout) void {
        allocator.destroy(layout);
    }
};

pub const ShaderModule = struct {
    manager: utils.Manager(ShaderModule) = .{},
    library: *mtl.Library,
    threadgroup_sizes: std.StringHashMap(mtl.Size),

    pub fn initAir(device: *Device, air: *const shader.Air) !*ShaderModule {
        const mtl_device = device.mtl_device;

        const code = shader.CodeGen.generate(allocator, air, .msl, .{ .emit_source_file = "" }) catch unreachable;
        defer allocator.free(code);

        var err: ?*ns.Error = undefined;
        var source = ns.String.alloc().initWithBytesNoCopy_length_encoding_freeWhenDone(
            @constCast(code.ptr),
            code.len,
            ns.UTF8StringEncoding,
            false,
        );
        var library = mtl_device.newLibraryWithSource_options_error(source, null, &err) orelse {
            std.log.err("{s}", .{err.?.localizedDescription().utf8String()});
            return error.InvalidDescriptor;
        };

        var module = try allocator.create(ShaderModule);
        module.* = .{
            .library = library,
            .threadgroup_sizes = std.StringHashMap(mtl.Size).init(allocator),
        };
        try module.reflect(air);
        return module;
    }

    pub fn deinit(shader_module: *ShaderModule) void {
        shader_module.library.release();
        shader_module.threadgroup_sizes.deinit();
        allocator.destroy(shader_module);
    }

    fn reflect(shader_module: *ShaderModule, air: *const shader.Air) !void {
        for (air.refToList(air.globals_index)) |inst_idx| {
            switch (air.getInst(inst_idx)) {
                .@"fn" => _ = try shader_module.reflectFn(air, inst_idx),
                else => {},
            }
        }
    }

    fn reflectFn(shader_module: *ShaderModule, air: *const shader.Air, inst_idx: shader.Air.InstIndex) !void {
        const inst = air.getInst(inst_idx).@"fn";
        const name = entrypointSlice(air.getStr(inst.name));

        switch (inst.stage) {
            .compute => |stage| {
                try shader_module.threadgroup_sizes.put(name, mtl.Size.init(
                    @intCast(air.resolveInt(stage.x) orelse 1),
                    @intCast(air.resolveInt(stage.y) orelse 1),
                    @intCast(air.resolveInt(stage.z) orelse 1),
                ));
            },
            else => {},
        }
    }
};

pub const ComputePipeline = struct {
    manager: utils.Manager(ComputePipeline) = .{},
    mtl_pipeline: *mtl.ComputePipelineState,
    layout: *BindGroupLayout,
    threadgroup_size: mtl.Size,

    pub fn init(device: *Device, desc: *const dgpu.ComputePipeline.Descriptor) !*ComputePipeline {
        const mtl_device = device.mtl_device;

        var mtl_desc = mtl.ComputePipelineDescriptor.alloc().init();
        defer mtl_desc.release();

        if (desc.label) |label| {
            mtl_desc.setLabel(ns.String.stringWithUTF8String(label));
        }

        const compute_module: *ShaderModule = @ptrCast(@alignCast(desc.compute.module));
        const entrypoint = entrypointString(desc.compute.entry_point);
        const compute_fn = compute_module.library.newFunctionWithName(ns.String.stringWithUTF8String(entrypoint)) orelse {
            return error.InvalidDescriptor;
        };
        defer compute_fn.release();
        mtl_desc.setComputeFunction(compute_fn);

        const threadgroup_size = compute_module.threadgroup_sizes.get(std.mem.span(entrypoint)) orelse {
            return error.InvalidDescriptor;
        };

        // create
        var err: ?*ns.Error = undefined;
        const mtl_pipeline = mtl_device.newComputePipelineStateWithDescriptor_options_reflection_error(
            mtl_desc,
            mtl.PipelineOptionNone,
            null,
            &err,
        ) orelse {
            // TODO
            std.log.err("{s}", .{err.?.localizedDescription().utf8String()});
            return error.InvalidDescriptor;
        };

        // result
        var pipeline = try allocator.create(ComputePipeline);
        pipeline.* = .{
            .mtl_pipeline = mtl_pipeline,
            .layout = try BindGroupLayout.initDefault(),
            .threadgroup_size = threadgroup_size,
        };
        return pipeline;
    }

    pub fn deinit(pipeline: *ComputePipeline) void {
        pipeline.mtl_pipeline.release();
        pipeline.layout.manager.release();
        allocator.destroy(pipeline);
    }

    pub fn getBindGroupLayout(pipeline: *ComputePipeline, group_index: u32) *BindGroupLayout {
        _ = group_index;
        return pipeline.layout;
    }
};

pub const RenderPipeline = struct {
    manager: utils.Manager(RenderPipeline) = .{},
    mtl_pipeline: *mtl.RenderPipelineState,
    layout: *BindGroupLayout,
    primitive_type: mtl.PrimitiveType,
    winding: mtl.Winding,
    cull_mode: mtl.CullMode,
    depth_stencil_state: ?*mtl.DepthStencilState,
    depth_bias: f32,
    depth_bias_slope_scale: f32,
    depth_bias_clamp: f32,

    pub fn init(device: *Device, desc: *const dgpu.RenderPipeline.Descriptor) !*RenderPipeline {
        const mtl_device = device.mtl_device;

        var mtl_desc = mtl.RenderPipelineDescriptor.alloc().init();
        defer mtl_desc.release();

        if (desc.label) |label| {
            mtl_desc.setLabel(ns.String.stringWithUTF8String(label));
        }

        // layout - TODO

        // vertex
        const vertex_module: *ShaderModule = @ptrCast(@alignCast(desc.vertex.module));
        const vertex_fn = vertex_module.library.newFunctionWithName(ns.String.stringWithUTF8String(desc.vertex.entry_point)) orelse {
            return error.InvalidDescriptor;
        };
        defer vertex_fn.release();
        mtl_desc.setVertexFunction(vertex_fn);

        // vertex constants - TODO
        if (desc.vertex.buffer_count > 0) {
            const mtl_vertex_descriptor = mtl.VertexDescriptor.vertexDescriptor();
            const mtl_layouts = mtl_vertex_descriptor.layouts();
            const mtl_attributes = mtl_vertex_descriptor.attributes();

            for (desc.vertex.buffers.?[0..desc.vertex.buffer_count], 0..) |buffer, i| {
                const buffer_index = slot_vertex_buffers + i;
                const mtl_layout = mtl_layouts.objectAtIndexedSubscript(buffer_index);
                mtl_layout.setStride(buffer.array_stride);
                mtl_layout.setStepFunction(conv.metalVertexStepFunction(buffer.step_mode));
                mtl_layout.setStepRate(1);
                for (buffer.attributes.?[0..buffer.attribute_count]) |attr| {
                    const mtl_attribute = mtl_attributes.objectAtIndexedSubscript(attr.shader_location);

                    mtl_attribute.setFormat(conv.metalVertexFormat(attr.format));
                    mtl_attribute.setOffset(attr.offset);
                    mtl_attribute.setBufferIndex(buffer_index);
                }
            }

            mtl_desc.setVertexDescriptor(mtl_vertex_descriptor);
        }

        // primitive
        const primitive_type = conv.metalPrimitiveType(desc.primitive.topology);
        mtl_desc.setInputPrimitiveTopology(conv.metalPrimitiveTopologyClass(desc.primitive.topology));
        // strip_index_format
        const winding = conv.metalWinding(desc.primitive.front_face);
        const cull_mode = conv.metalCullMode(desc.primitive.cull_mode);

        // depth-stencil
        const depth_stencil_state = blk: {
            if (desc.depth_stencil) |ds| {
                var front_desc = mtl.StencilDescriptor.alloc().init();
                defer front_desc.release();

                front_desc.setStencilCompareFunction(conv.metalCompareFunction(ds.stencil_front.compare));
                front_desc.setStencilFailureOperation(conv.metalStencilOperation(ds.stencil_front.fail_op));
                front_desc.setDepthFailureOperation(conv.metalStencilOperation(ds.stencil_front.depth_fail_op));
                front_desc.setDepthStencilPassOperation(conv.metalStencilOperation(ds.stencil_front.pass_op));
                front_desc.setReadMask(ds.stencil_read_mask);
                front_desc.setWriteMask(ds.stencil_write_mask);

                var back_desc = mtl.StencilDescriptor.alloc().init();
                defer back_desc.release();

                back_desc.setStencilCompareFunction(conv.metalCompareFunction(ds.stencil_back.compare));
                back_desc.setStencilFailureOperation(conv.metalStencilOperation(ds.stencil_back.fail_op));
                back_desc.setDepthFailureOperation(conv.metalStencilOperation(ds.stencil_back.depth_fail_op));
                back_desc.setDepthStencilPassOperation(conv.metalStencilOperation(ds.stencil_back.pass_op));
                back_desc.setReadMask(ds.stencil_read_mask);
                back_desc.setWriteMask(ds.stencil_write_mask);

                var depth_stencil_desc = mtl.DepthStencilDescriptor.alloc().init();
                defer depth_stencil_desc.release();

                depth_stencil_desc.setDepthCompareFunction(conv.metalCompareFunction(ds.depth_compare));
                depth_stencil_desc.setDepthWriteEnabled(ds.depth_write_enabled == .true);
                depth_stencil_desc.setFrontFaceStencil(front_desc);
                depth_stencil_desc.setBackFaceStencil(back_desc);
                if (desc.label) |label| {
                    depth_stencil_desc.setLabel(ns.String.stringWithUTF8String(label));
                }

                break :blk mtl_device.newDepthStencilStateWithDescriptor(depth_stencil_desc);
            } else {
                break :blk null;
            }
        };
        const depth_bias = if (desc.depth_stencil != null) @as(f32, @floatFromInt(desc.depth_stencil.?.depth_bias)) else 0.0; // TODO - int to float conversion
        const depth_bias_slope_scale = if (desc.depth_stencil != null) desc.depth_stencil.?.depth_bias_slope_scale else 0.0;
        const depth_bias_clamp = if (desc.depth_stencil != null) desc.depth_stencil.?.depth_bias_clamp else 0.0;

        // multisample
        mtl_desc.setSampleCount(desc.multisample.count);
        // mask - TODO
        mtl_desc.setAlphaToCoverageEnabled(desc.multisample.alpha_to_coverage_enabled == .true);

        // fragment
        if (desc.fragment) |frag| {
            const frag_module: *ShaderModule = @ptrCast(@alignCast(frag.module));
            const frag_fn = frag_module.library.newFunctionWithName(ns.String.stringWithUTF8String(frag.entry_point)) orelse {
                return error.InvalidDescriptor;
            };
            defer frag_fn.release();
            mtl_desc.setFragmentFunction(frag_fn);
        }

        // attachments
        if (desc.fragment) |frag| {
            for (frag.targets.?[0..frag.target_count], 0..) |target, i| {
                var attach = mtl_desc.colorAttachments().objectAtIndexedSubscript(i);

                attach.setPixelFormat(conv.metalPixelFormat(target.format));
                attach.setWriteMask(conv.metalColorWriteMask(target.write_mask));
                if (target.blend) |blend| {
                    attach.setBlendingEnabled(true);
                    attach.setSourceRGBBlendFactor(conv.metalBlendFactor(blend.color.src_factor));
                    attach.setDestinationRGBBlendFactor(conv.metalBlendFactor(blend.color.dst_factor));
                    attach.setRgbBlendOperation(conv.metalBlendOperation(blend.color.operation));
                    attach.setSourceAlphaBlendFactor(conv.metalBlendFactor(blend.alpha.src_factor));
                    attach.setDestinationAlphaBlendFactor(conv.metalBlendFactor(blend.alpha.dst_factor));
                    attach.setAlphaBlendOperation(conv.metalBlendOperation(blend.alpha.operation));
                }
            }
        }
        if (desc.depth_stencil) |ds| {
            mtl_desc.setDepthAttachmentPixelFormat(conv.metalPixelFormat(ds.format));
            mtl_desc.setStencilAttachmentPixelFormat(conv.metalPixelFormat(ds.format));
        }

        // create
        var err: ?*ns.Error = undefined;
        const mtl_pipeline = mtl_device.newRenderPipelineStateWithDescriptor_error(mtl_desc, &err) orelse {
            // TODO
            std.log.err("{s}", .{err.?.localizedDescription().utf8String()});
            return error.InvalidDescriptor;
        };

        var pipeline = try allocator.create(RenderPipeline);
        pipeline.* = .{
            .mtl_pipeline = mtl_pipeline,
            .layout = try BindGroupLayout.initDefault(),
            .primitive_type = primitive_type,
            .winding = winding,
            .cull_mode = cull_mode,
            .depth_stencil_state = depth_stencil_state,
            .depth_bias = depth_bias,
            .depth_bias_slope_scale = depth_bias_slope_scale,
            .depth_bias_clamp = depth_bias_clamp,
        };
        return pipeline;
    }

    pub fn deinit(pipeline: *RenderPipeline) void {
        pipeline.mtl_pipeline.release();
        pipeline.layout.manager.release();
        allocator.destroy(pipeline);
    }

    pub fn getBindGroupLayout(pipeline: *RenderPipeline, group_index: u32) *BindGroupLayout {
        _ = group_index;
        return pipeline.layout;
    }
};

pub const CommandBuffer = struct {
    manager: utils.Manager(CommandBuffer) = .{},
    mtl_command_buffer: *mtl.CommandBuffer,
    referenced_buffers: std.ArrayList(*Buffer),

    pub fn init(device: *Device) !*CommandBuffer {
        const queue = try device.getQueue();
        var mtl_command_buffer = queue.command_queue.commandBuffer() orelse {
            return error.newCommandBufferFailed;
        };

        var cmd_buffer = try allocator.create(CommandBuffer);
        cmd_buffer.* = .{
            .mtl_command_buffer = mtl_command_buffer,
            .referenced_buffers = std.ArrayList(*Buffer).init(allocator),
        };
        return cmd_buffer;
    }

    pub fn deinit(command_buffer: *CommandBuffer) void {
        command_buffer.referenced_buffers.deinit();
        allocator.destroy(command_buffer);
    }
};

pub const CommandEncoder = struct {
    manager: utils.Manager(CommandEncoder) = .{},
    device: *Device,
    command_buffer: *CommandBuffer,
    referenced_buffers: *std.ArrayList(*Buffer),

    pub fn init(device: *Device, desc: ?*const dgpu.CommandEncoder.Descriptor) !*CommandEncoder {
        // TODO
        _ = desc;

        const command_buffer = try CommandBuffer.init(device);

        var encoder = try allocator.create(CommandEncoder);
        encoder.* = .{
            .device = device,
            .command_buffer = command_buffer,
            .referenced_buffers = &command_buffer.referenced_buffers,
        };
        return encoder;
    }

    pub fn deinit(encoder: *CommandEncoder) void {
        encoder.command_buffer.manager.release();
        allocator.destroy(encoder);
    }

    pub fn beginComputePass(encoder: *CommandEncoder, desc: *const dgpu.ComputePassDescriptor) !*ComputePassEncoder {
        return ComputePassEncoder.init(encoder, desc);
    }

    pub fn beginRenderPass(encoder: *CommandEncoder, desc: *const dgpu.RenderPassDescriptor) !*RenderPassEncoder {
        return RenderPassEncoder.init(encoder, desc);
    }

    pub fn copyBufferToBuffer(encoder: *CommandEncoder, source: *Buffer, source_offset: u64, destination: *Buffer, destination_offset: u64, size: u64) !void {
        const command_buffer = encoder.command_buffer;
        const mtl_command_buffer = command_buffer.mtl_command_buffer;

        var mtl_desc = mtl.BlitPassDescriptor.new();
        defer mtl_desc.release();

        const mtl_encoder = mtl_command_buffer.blitCommandEncoderWithDescriptor(mtl_desc) orelse {
            return error.InvalidDescriptor;
        };

        mtl_encoder.copyFromBuffer_sourceOffset_toBuffer_destinationOffset_size(
            source.mtl_buffer,
            source_offset,
            destination.mtl_buffer,
            destination_offset,
            size,
        );

        try encoder.referenced_buffers.append(source);
        try encoder.referenced_buffers.append(destination);

        mtl_encoder.endEncoding();
    }

    pub fn finish(encoder: *CommandEncoder, desc: *const dgpu.CommandBuffer.Descriptor) !*CommandBuffer {
        const command_buffer = encoder.command_buffer;
        const mtl_command_buffer = command_buffer.mtl_command_buffer;

        if (desc.label) |label| {
            mtl_command_buffer.setLabel(ns.String.stringWithUTF8String(label));
        }

        return command_buffer;
    }
};

pub const ComputePassEncoder = struct {
    manager: utils.Manager(ComputePassEncoder) = .{},
    mtl_encoder: *mtl.ComputeCommandEncoder,
    lengths_buffer: *mtl.Buffer,
    referenced_buffers: *std.ArrayList(*Buffer),
    threadgroup_size: mtl.Size,

    pub fn init(command_encoder: *CommandEncoder, desc: *const dgpu.ComputePassDescriptor) !*ComputePassEncoder {
        const mtl_device = command_encoder.device.mtl_device;
        const mtl_command_buffer = command_encoder.command_buffer.mtl_command_buffer;

        var mtl_desc = mtl.ComputePassDescriptor.new();
        defer mtl_desc.release();

        const mtl_encoder = mtl_command_buffer.computeCommandEncoderWithDescriptor(mtl_desc) orelse {
            return error.InvalidDescriptor;
        };

        if (desc.label) |label| {
            mtl_encoder.setLabel(ns.String.stringWithUTF8String(label));
        }

        // TODO - needs to be N slots and recycle memory
        const lengths_buffer = mtl_device.newBufferWithLength_options(@sizeOf(u32), 0) orelse {
            return error.newBufferFailed;
        };

        mtl_encoder.setBuffer_offset_atIndex(lengths_buffer, 0, slot_buffer_lengths);

        var encoder = try allocator.create(ComputePassEncoder);
        encoder.* = .{
            .mtl_encoder = mtl_encoder,
            .lengths_buffer = lengths_buffer,
            .referenced_buffers = command_encoder.referenced_buffers,
            .threadgroup_size = mtl.Size.init(0, 0, 0),
        };
        return encoder;
    }

    pub fn deinit(encoder: *ComputePassEncoder) void {
        encoder.lengths_buffer.release();
        allocator.destroy(encoder);
    }

    pub fn dispatchWorkgroups(encoder: *ComputePassEncoder, workgroup_count_x: u32, workgroup_count_y: u32, workgroup_count_z: u32) void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.dispatchThreadgroups_threadsPerThreadgroup(
            mtl.Size.init(workgroup_count_x, workgroup_count_y, workgroup_count_z),
            encoder.threadgroup_size,
        );
    }

    pub fn end(encoder: *ComputePassEncoder) void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.endEncoding();
    }

    pub fn setBindGroup(encoder: *ComputePassEncoder, group_index: u32, group: *BindGroup, dynamic_offset_count: usize, dynamic_offsets: ?[*]const u32) !void {
        _ = group_index;
        _ = dynamic_offsets;
        _ = dynamic_offset_count;

        const mtl_encoder = encoder.mtl_encoder;

        for (group.entries) |entry| {
            switch (entry.kind) {
                .buffer => {
                    try encoder.referenced_buffers.append(entry.buffer.?);
                    mtl_encoder.setBytes_length_atIndex(&entry.size, @sizeOf(u32), slot_buffer_lengths);
                    mtl_encoder.setBuffer_offset_atIndex(entry.buffer.?.mtl_buffer, entry.offset, entry.binding);
                },
                .sampler => mtl_encoder.setSamplerState_atIndex(entry.sampler, entry.binding),
                .texture => mtl_encoder.setTexture_atIndex(entry.texture, entry.binding),
            }
        }
    }

    pub fn setPipeline(encoder: *ComputePassEncoder, pipeline: *ComputePipeline) !void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.setComputePipelineState(pipeline.mtl_pipeline);
        encoder.threadgroup_size = pipeline.threadgroup_size;
    }
};

pub const RenderPassEncoder = struct {
    manager: utils.Manager(RenderPassEncoder) = .{},
    mtl_encoder: *mtl.RenderCommandEncoder,
    vertex_lengths_buffer: *mtl.Buffer,
    fragment_lengths_buffer: *mtl.Buffer,
    referenced_buffers: *std.ArrayList(*Buffer),
    primitive_type: mtl.PrimitiveType = mtl.PrimitiveTypeTriangle,

    pub fn init(command_encoder: *CommandEncoder, desc: *const dgpu.RenderPassDescriptor) !*RenderPassEncoder {
        const mtl_device = command_encoder.device.mtl_device;
        const mtl_command_buffer = command_encoder.command_buffer.mtl_command_buffer;

        var mtl_desc = mtl.RenderPassDescriptor.new();
        defer mtl_desc.release();

        // color
        for (desc.color_attachments.?[0..desc.color_attachment_count], 0..) |attach, i| {
            var mtl_attach = mtl_desc.colorAttachments().objectAtIndexedSubscript(i);
            if (attach.view) |view| {
                const mtl_view: *TextureView = @ptrCast(@alignCast(view));
                mtl_attach.setTexture(mtl_view.mtl_texture);
            }
            if (attach.resolve_target) |view| {
                const mtl_view: *TextureView = @ptrCast(@alignCast(view));
                mtl_attach.setResolveTexture(mtl_view.mtl_texture);
            }
            mtl_attach.setLoadAction(conv.metalLoadAction(attach.load_op));
            mtl_attach.setStoreAction(conv.metalStoreAction(attach.store_op, attach.resolve_target != null));

            if (attach.load_op == .clear) {
                mtl_attach.setClearColor(mtl.ClearColor.init(
                    @floatCast(attach.clear_value.r),
                    @floatCast(attach.clear_value.g),
                    @floatCast(attach.clear_value.b),
                    @floatCast(attach.clear_value.a),
                ));
            }
        }

        // depth-stencil
        if (desc.depth_stencil_attachment) |attach| {
            const mtl_view: *TextureView = @ptrCast(@alignCast(attach.view));
            const format = mtl_view.mtl_texture.pixelFormat();

            if (isDepthFormat(format)) {
                var mtl_attach = mtl_desc.depthAttachment();

                mtl_attach.setTexture(mtl_view.mtl_texture);
                mtl_attach.setLoadAction(conv.metalLoadAction(attach.depth_load_op));
                mtl_attach.setStoreAction(conv.metalStoreAction(attach.depth_store_op, false));

                if (attach.depth_load_op == .clear) {
                    mtl_attach.setClearDepth(attach.depth_clear_value);
                }
            }

            if (isStencilFormat(format)) {
                var mtl_attach = mtl_desc.stencilAttachment();

                mtl_attach.setTexture(mtl_view.mtl_texture);
                mtl_attach.setLoadAction(conv.metalLoadAction(attach.stencil_load_op));
                mtl_attach.setStoreAction(conv.metalStoreAction(attach.stencil_store_op, false));

                if (attach.stencil_load_op == .clear) {
                    mtl_attach.setClearStencil(attach.stencil_clear_value);
                }
            }
        }

        // occlusion_query - TODO
        // timestamps - TODO

        const mtl_encoder = mtl_command_buffer.renderCommandEncoderWithDescriptor(mtl_desc) orelse {
            return error.InvalidDescriptor;
        };

        if (desc.label) |label| {
            mtl_encoder.setLabel(ns.String.stringWithUTF8String(label));
        }

        // TODO - needs to be N slots and recycle memory
        const vertex_lengths_buffer = mtl_device.newBufferWithLength_options(@sizeOf(u32), 0) orelse {
            return error.newBufferFailed;
        };
        const fragment_lengths_buffer = mtl_device.newBufferWithLength_options(@sizeOf(u32), 0) orelse {
            return error.newBufferFailed;
        };

        mtl_encoder.setVertexBuffer_offset_atIndex(vertex_lengths_buffer, 0, slot_buffer_lengths);
        mtl_encoder.setFragmentBuffer_offset_atIndex(fragment_lengths_buffer, 0, slot_buffer_lengths);

        var encoder = try allocator.create(RenderPassEncoder);
        encoder.* = .{
            .mtl_encoder = mtl_encoder,
            .vertex_lengths_buffer = vertex_lengths_buffer,
            .fragment_lengths_buffer = fragment_lengths_buffer,
            .referenced_buffers = command_encoder.referenced_buffers,
        };
        return encoder;
    }

    pub fn deinit(encoder: *RenderPassEncoder) void {
        encoder.vertex_lengths_buffer.release();
        encoder.fragment_lengths_buffer.release();
        allocator.destroy(encoder);
    }

    pub fn draw(encoder: *RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.drawPrimitives_vertexStart_vertexCount_instanceCount_baseInstance(
            encoder.primitive_type,
            first_vertex,
            vertex_count,
            instance_count,
            first_instance,
        );
    }

    pub fn end(encoder: *RenderPassEncoder) void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.endEncoding();
    }

    pub fn setBindGroup(encoder: *RenderPassEncoder, group_index: u32, group: *BindGroup, dynamic_offset_count: usize, dynamic_offsets: ?[*]const u32) !void {
        _ = dynamic_offsets;
        _ = dynamic_offset_count;
        _ = group_index;
        const mtl_encoder = encoder.mtl_encoder;

        // TODO - need stage info
        for (group.entries) |entry| {
            switch (entry.kind) {
                .buffer => {
                    try encoder.referenced_buffers.append(entry.buffer.?);
                    mtl_encoder.setVertexBytes_length_atIndex(&entry.size, @sizeOf(u32), slot_buffer_lengths);
                    mtl_encoder.setVertexBuffer_offset_atIndex(entry.buffer.?.mtl_buffer, entry.offset, entry.binding);
                },
                .sampler => mtl_encoder.setFragmentSamplerState_atIndex(entry.sampler, entry.binding),
                .texture => mtl_encoder.setFragmentTexture_atIndex(entry.texture, entry.binding),
            }
        }
    }

    pub fn setPipeline(encoder: *RenderPassEncoder, pipeline: *RenderPipeline) !void {
        const mtl_encoder = encoder.mtl_encoder;
        mtl_encoder.setRenderPipelineState(pipeline.mtl_pipeline);
        mtl_encoder.setFrontFacingWinding(pipeline.winding);
        mtl_encoder.setCullMode(pipeline.cull_mode);
        if (pipeline.depth_stencil_state) |state| {
            mtl_encoder.setDepthStencilState(state);
            mtl_encoder.setDepthBias_slopeScale_clamp(
                pipeline.depth_bias,
                pipeline.depth_bias_slope_scale,
                pipeline.depth_bias_clamp,
            );
        }
        encoder.primitive_type = pipeline.primitive_type;
    }

    pub fn setVertexBuffer(encoder: *RenderPassEncoder, slot: u32, buffer: *Buffer, offset: u64, size: u64) !void {
        const mtl_encoder = encoder.mtl_encoder;
        const size_u32 = @as(u32, @intCast(size));
        try encoder.referenced_buffers.append(buffer);
        mtl_encoder.setVertexBytes_length_atIndex(&size_u32, @sizeOf(u32), slot_buffer_lengths);
        mtl_encoder.setVertexBuffer_offset_atIndex(buffer.mtl_buffer, offset, slot_vertex_buffers + slot);
    }
};

pub const Queue = struct {
    const CompletedContext = extern struct {
        queue: *Queue,
        fence_value: u64,
    };

    manager: utils.Manager(Queue) = .{},
    device: *Device,
    command_queue: *mtl.CommandQueue,
    fence_value: u64 = 0,
    completed_value: u64 = 0, // TODO - this should be an atomic as it's updated in the callback on other threads

    pub fn init(device: *Device) !*Queue {
        const mtl_device = device.mtl_device;

        const command_queue = mtl_device.newCommandQueue() orelse {
            return error.NoCommandQueue;
        };

        var queue = try allocator.create(Queue);
        queue.* = .{
            .device = device,
            .command_queue = command_queue,
        };
        return queue;
    }

    pub fn deinit(queue: *Queue) void {
        queue.command_queue.release();
        allocator.destroy(queue);
    }

    pub fn submit(queue: *Queue, commands: []const *CommandBuffer) !void {
        for (commands) |command_buffer| {
            const mtl_command_buffer = command_buffer.mtl_command_buffer;

            queue.fence_value += 1;

            for (command_buffer.referenced_buffers.items) |buffer| {
                buffer.last_used_fence_value = queue.fence_value;
            }

            const ctx = CompletedContext{
                .queue = queue,
                .fence_value = queue.fence_value,
            };
            mtl_command_buffer.addCompletedHandler(ctx, completedHandler);
            mtl_command_buffer.commit();
        }
    }

    pub fn writeBuffer(queue: *Queue, buffer: *Buffer, offset: u64, data: [*]const u8, size: u64) !void {
        // TODO - need an upload manager
        const stage_buffer = try Buffer.init(queue.device, &.{
            .usage = .{
                .copy_src = true,
                .map_write = true,
            },
            .size = size,
            .mapped_at_creation = .true,
        });
        defer stage_buffer.manager.release();

        const map: [*]u8 = @ptrCast(stage_buffer.mtl_buffer.contents());
        @memcpy(map[0..size], data[0..size]);
        var cmd_encoder = try CommandEncoder.init(queue.device, null);
        defer cmd_encoder.manager.release();

        try cmd_encoder.copyBufferToBuffer(stage_buffer, offset, buffer, offset, size);
        const cmd_buffer = try cmd_encoder.finish(&.{});
        cmd_buffer.manager.reference(); // handled in main.zig
        defer cmd_buffer.manager.release();

        try queue.submit(&[_]*CommandBuffer{cmd_buffer});
    }

    fn completedHandler(ctx: CompletedContext, mtl_command_buffer: *mtl.CommandBuffer) void {
        _ = mtl_command_buffer;
        ctx.queue.completed_value = ctx.fence_value;
    }
};

test "reference declarations" {
    std.testing.refAllDeclsRecursive(@This());
}
