const std = @import("std");

const math = @import("libtess2_example.zig").math;
const dvui = @import("libtess2_example.zig").dvui;

const Transform = math.Transform;
const BBox = math.BBox;
const FloatPair = math.FloatPair;

pub fn mousePos() dvui.Point {
    const events = dvui.events();
    return events[events.len - 1].evt.mouse.p;
}

pub fn mouseWorldPos(pos: dvui.Point.Physical, wd_rs: dvui.RectScale, transform: Transform) FloatPair {
    const mouse_target_pos = wd_rs.pointFromPhysical(pos);
    const mouse_source_pos = transform.inverse().transformPoint(.fromDvui(mouse_target_pos));
    return mouse_source_pos;
}
pub const DragTransformConstrained = struct {
    transform: Transform,
    source_bbox: BBox,
    max_zoom_mult: f32 = 10.0,

    pub fn translation(self: DragTransformConstrained) FloatPair {
        return self.transform.translation;
    }

    pub fn scaling_factor(self: DragTransformConstrained) f32 {
        return self.transform.scaling_factor;
    }

    /// Makes sure that image of source could fully cover target with some transform.
    pub fn constrainScale(self: DragTransformConstrained, target: BBox) DragTransformConstrained {
        const min_scale = @max(target.width() / self.source_bbox.width(), target.height() / self.source_bbox.height());
        const max_scale = min_scale * self.max_zoom_mult;
        const out_scaling_factor = @max(@min(self.scaling_factor(), max_scale), min_scale);
        return .{
            .transform = .{ .scaling_factor = out_scaling_factor, .translation = self.translation() },
            .source_bbox = self.source_bbox,
            .max_zoom_mult = self.max_zoom_mult,
        };
    }

    /// Makes sure that image of source fully covers target, assuming scale allows it.
    pub fn constrainTranslation(self: DragTransformConstrained, target: BBox) DragTransformConstrained {
        const min_dv = target.bottomRight().sub(self.source_bbox.bottomRight().mulScalar(self.scaling_factor()));
        const max_dv = target.topLeft().sub(self.source_bbox.topLeft().mulScalar(self.scaling_factor()));

        var out_translation = self.translation();
        out_translation = .{ .x = @max(out_translation.x, min_dv.x), .y = @max(out_translation.y, min_dv.y) };
        out_translation = .{ .x = @min(out_translation.x, max_dv.x), .y = @min(out_translation.y, max_dv.y) };
        return .{
            .transform = .{ .scaling_factor = self.scaling_factor(), .translation = out_translation },
            .source_bbox = self.source_bbox,
            .max_zoom_mult = self.max_zoom_mult,
        };
    }

    /// Makes sure that image of source fully covers target.
    pub fn constrain(self: DragTransformConstrained, target: BBox) DragTransformConstrained {
        return self.constrainScale(target).constrainTranslation(target);
    }

    /// Returns mouse position in source coordinates
    pub fn processEvents(self: *DragTransformConstrained, wd: dvui.WidgetData) void {
        const target_bbox: BBox = .fromDvuiRect(wd.contentRect().justSize());
        for (dvui.events()) |*e| {
            switch (e.evt) {
                .mouse => |me| {
                    if (!dvui.eventMatch(e, .{ .id = wd.id, .r = wd.contentRectScale().r })) {
                        continue;
                    }
                    if (me.action == .wheel_y) {
                        // Zoom while trying to keep point under mouse stable
                        const mouse_source_pos = mouseWorldPos(me.p, wd.contentRectScale(), self.transform);

                        const old_scaling_factor = self.transform.scaling_factor;
                        self.transform = self.transform.scale(if (me.action.wheel_y > 0) 1.1 else 1.0 / 1.1);
                        self.* = self.constrainScale(target_bbox);

                        self.transform.translation = mouse_source_pos.mulScalar(old_scaling_factor - self.transform.scaling_factor).add(self.transform.translation);
                        self.* = self.constrainTranslation(target_bbox);

                        e.handle(@src(), &wd);
                        dvui.refresh(null, @src(), wd.id);
                    } else if (me.action == .press and me.button == .right) {
                        e.handle(@src(), &wd);
                        dvui.captureMouse(&wd, e.num);
                        dvui.dragPreStart(.right, me.p, .{});
                    } else if (me.action == .motion) {
                        if (dvui.captured(wd.id)) {
                            if (dvui.dragging(me.p, null)) |dp| {
                                self.transform = self.transform.translate2(dp.x, dp.y);
                                self.* = self.constrainTranslation(target_bbox);
                            }
                            dvui.captureMouse(&wd, e.num);
                        }
                    } else if (me.action == .release and me.button == .right) {
                        if (dvui.captured(wd.id)) {
                            e.handle(@src(), &wd);
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd();
                        }
                    }
                    if (me.action == .position) {
                        self.* = self.constrain(target_bbox);
                    }
                },
                else => {},
            }
        }
    }
};

pub const Triangles = struct {
    pub const Vertex = struct {
        pos: FloatPair,
        col: dvui.Color.PMA,
    };

    pub const Builder = struct {
        vertexes: std.ArrayList(Vertex) = .empty,
        indices: std.ArrayList(dvui.Vertex.Index) = .empty,
        bbox: BBox = .degenerate,

        pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
            self.vertexes.deinit(gpa);
            self.indices.deinit(gpa);
        }

        pub fn addMultipleTriangles(
            self: *Builder,
            gpa: std.mem.Allocator,
            vertexes: []const Vertex,
            indices: []const dvui.Vertex.Index,
        ) !void {
            const vertex_start = self.vertexes.items.len;
            const index_start = self.indices.items.len;
            try self.vertexes.appendSlice(gpa, vertexes);
            try self.indices.appendSlice(gpa, indices);
            for (self.indices.items[index_start..]) |*idx| {
                idx.* += @intCast(vertex_start);
            }

            for (vertexes) |v| {
                self.bbox = self.bbox.expandToFitPoint(v.pos);
            }
        }

        pub fn addOneTriangle(
            self: *Builder,
            gpa: std.mem.Allocator,
            p1: FloatPair,
            p2: FloatPair,
            p3: FloatPair,
            col: dvui.Color.PMA,
        ) !void {
            const vertex_start = self.vertexes.items.len;
            try self.vertexes.append(gpa, .{ .pos = p1, .col = col });
            try self.vertexes.append(gpa, .{ .pos = p2, .col = col });
            try self.vertexes.append(gpa, .{ .pos = p3, .col = col });
            try self.indices.append(gpa, @intCast(vertex_start));
            try self.indices.append(gpa, @intCast(vertex_start + 1));
            try self.indices.append(gpa, @intCast(vertex_start + 2));

            self.bbox = self.bbox.expandToFitPoint(p1);
            self.bbox = self.bbox.expandToFitPoint(p2);
            self.bbox = self.bbox.expandToFitPoint(p3);
        }

        pub fn triangles(self: Builder) Triangles {
            return .{
                .vertexes = self.vertexes.items,
                .indices = self.indices.items,
                .bbox = self.bbox,
            };
        }

        pub fn clearRetainingCapacity(self: *Builder) void {
            self.vertexes.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
            self.bbox = .degenerate;
        }
    };

    vertexes: []Vertex,
    indices: []dvui.Vertex.Index,
    bbox: BBox = .degenerate,

    pub fn deinit(self: *Triangles, alloc: std.mem.Allocator) void {
        alloc.free(self.vertexes);
        alloc.free(self.indices);
    }
};

pub fn addBox(builder: *Triangles.Builder, gpa: std.mem.Allocator, point: FloatPair, radius: f32, pma: dvui.Color.PMA) !void {
    const vertices = [_]Triangles.Vertex{
        Triangles.Vertex{ .pos = .{ .x = point.x - radius, .y = point.y - radius }, .col = pma },
        Triangles.Vertex{ .pos = .{ .x = point.x + radius, .y = point.y - radius }, .col = pma },
        Triangles.Vertex{ .pos = .{ .x = point.x + radius, .y = point.y + radius }, .col = pma },
        Triangles.Vertex{ .pos = .{ .x = point.x - radius, .y = point.y + radius }, .col = pma },
    };
    const indices = [_]dvui.Vertex.Index{ 0, 1, 2, 2, 3, 0 };

    try builder.addMultipleTriangles(gpa, &vertices, &indices);
}

pub fn addLine(
    builder: *Triangles.Builder,
    gpa: std.mem.Allocator,
    p1: FloatPair,
    p2: FloatPair,
    width: f32,
    pma: dvui.Color.PMA,
) !void {
    if (p1.eq(p2)) {
        try addBox(builder, gpa, p1, width / 2, pma);
        return;
    }
    var dv = p2.sub(p1);
    dv = dv.mulScalar(width / 2 / dv.norm());
    const dv_perp: FloatPair = .{ .x = -dv.y, .y = dv.x };
    const vertices = [_]Triangles.Vertex{
        Triangles.Vertex{ .pos = p1.sub(dv).add(dv_perp), .col = pma },
        Triangles.Vertex{ .pos = p2.add(dv).add(dv_perp), .col = pma },
        Triangles.Vertex{ .pos = p2.add(dv).sub(dv_perp), .col = pma },
        Triangles.Vertex{ .pos = p1.sub(dv).sub(dv_perp), .col = pma },
    };
    const indices = [_]dvui.Vertex.Index{ 0, 1, 2, 2, 3, 0 };
    try builder.addMultipleTriangles(gpa, &vertices, &indices);
}

pub fn addArrow(
    builder: *Triangles.Builder,
    gpa: std.mem.Allocator,
    p1: FloatPair,
    p2: FloatPair,
    width: f32,
    marker_length: f32,
    radians_offset: f32,
    pma: dvui.Color.PMA,
) !void {
    try addLine(
        builder,
        gpa,
        p1,
        p2,
        width,
        pma,
    );
    var dp: FloatPair = p2.sub(p1);
    dp = dp.mulScalar(marker_length / dp.norm());
    const dp1 = dp.rotate(std.math.pi + radians_offset);
    const dp2 = dp.rotate(std.math.pi - radians_offset);
    try addLine(
        builder,
        gpa,
        p2,
        p2.add(dp1),
        width,
        pma,
    );
    try addLine(
        builder,
        gpa,
        p2,
        p2.add(dp2),
        width,
        pma,
    );
}

/// dvui_triangles must have enough space to fit triangles
pub fn renderTriangles(
    triangles: Triangles,
    dvui_triangles: *dvui.Triangles,
    tex: ?dvui.Texture,
    wd_rs: dvui.RectScale,
    transform: Transform,
) !void {
    if (dvui_triangles.vertexes.len < triangles.vertexes.len or dvui_triangles.indices.len < triangles.indices.len) {
        return error.NoSpace;
    }

    const idx_len = dvui_triangles.indices.len;
    const ver_len = dvui_triangles.vertexes.len;
    defer {
        dvui_triangles.indices.len = idx_len;
        dvui_triangles.vertexes.len = ver_len;
    }
    dvui_triangles.indices.len = triangles.indices.len;
    dvui_triangles.vertexes.len = triangles.vertexes.len;

    for (triangles.indices, 0..) |idx, i| {
        dvui_triangles.indices[i] = @intCast(idx);
    }
    for (triangles.vertexes, 0..) |v, i| {
        const pos = v.pos;
        const logical_point = transform.transformPoint(pos).asDvui();
        const physical_point = wd_rs.pointToPhysical(logical_point);

        dvui_triangles.vertexes[i] = .{
            .pos = physical_point,
            .col = v.col,
        };
    }
    const bbox = triangles.bbox;
    const logical_rect = bbox.transform(transform).asDvuiRect();
    const physical_rect = wd_rs.rectToPhysical(logical_rect);
    dvui_triangles.bounds = physical_rect;

    try dvui.renderTriangles(dvui_triangles.*, tex);
}

pub fn SliderIntInitOptions(comptime T: type) type {
    return struct {
        fraction: *T,
        min: T,
        max: T,

        dir: dvui.enums.Direction = .horizontal,

        /// Color of the left/top side of the slider.  If null, uses Theme.highlight.fill
        color_bar: ?dvui.Color = null,
    };
}
pub fn sliderInt(src: std.builtin.SourceLocation, comptime T: type, init_opts: SliderIntInitOptions(T), opts: dvui.Options) bool {
    std.debug.assert(init_opts.min <= init_opts.max);
    std.debug.assert(init_opts.min >= std.math.minInt(T));
    std.debug.assert(init_opts.max <= std.math.maxInt(T));
    if (init_opts.fraction.* < init_opts.min) {
        init_opts.fraction.* = init_opts.min;
    }
    if (init_opts.fraction.* > init_opts.max) {
        init_opts.fraction.* = init_opts.max;
    }

    const options = dvui.slider_defaults.override(opts);

    var b = dvui.box(src, .{ .dir = init_opts.dir }, options);
    defer b.deinit();

    if (b.data().accesskit_node()) |ak_node| {
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.focus);
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.set_value);
        dvui.AccessKit.nodeSetOrientation(ak_node, switch (init_opts.dir) {
            .vertical => dvui.AccessKit.Orientation.vertical,
            .horizontal => dvui.AccessKit.Orientation.horizontal,
        });
        dvui.AccessKit.nodeSetNumericValue(ak_node, init_opts.fraction.*);
        dvui.AccessKit.nodeSetMinNumericValue(ak_node, init_opts.min);
        dvui.AccessKit.nodeSetMaxNumericValue(ak_node, init_opts.max);
        dvui.AccessKit.nodeSetNumericValueStep(ak_node, 1);
        dvui.AccessKit.nodeSetNumericValueJump(ak_node, 10);
    }

    dvui.tabIndexSet(b.data().id, options.tab_index, b.data().rectScale().r);

    var hovered: bool = false;
    var ret = false;

    const br = b.data().contentRect();
    const knobsize = @min(br.w, br.h);
    const track = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = knobsize / 2, .y = br.h / 2 - 2, .w = br.w - knobsize, .h = 4 },
        .vertical => dvui.Rect{ .x = br.w / 2 - 2, .y = knobsize / 2, .w = 4, .h = br.h - knobsize },
    };

    const trackrs = b.widget().screenRectScale(track);

    const rs = b.data().contentRectScale();
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = b.data().id, .r = rs.r }))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                var p: ?dvui.Point.Physical = null;
                if (me.action == .focus) {
                    e.handle(@src(), b.data());
                    dvui.focusWidget(b.data().id, null, e.num);
                } else if (me.action == .press and me.button.pointer()) {
                    // capture
                    dvui.captureMouse(b.data(), e.num);
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .release and me.button.pointer()) {
                    // stop capture
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    e.handle(@src(), b.data());
                } else if (me.action == .motion and dvui.captured(b.data().id)) {
                    // handle only if we have capture
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .position) {
                    dvui.cursorSet(.arrow);
                    hovered = true;
                }

                if (p) |pp| {
                    var min: f32 = undefined;
                    var max: f32 = undefined;
                    switch (init_opts.dir) {
                        .horizontal => {
                            min = trackrs.r.x;
                            max = trackrs.r.x + trackrs.r.w;
                        },
                        .vertical => {
                            min = 0;
                            max = trackrs.r.h;
                        },
                    }

                    if (max > min) {
                        const v = if (init_opts.dir == .horizontal) pp.x else (trackrs.r.y + trackrs.r.h - pp.y);
                        const float_fraction = std.math.clamp((v - min) / (max - min), 0, 1);
                        const offset: f32 = float_fraction * @as(f32, @floatFromInt(init_opts.max - init_opts.min));
                        init_opts.fraction.* = init_opts.min + @as(T, @round(offset));
                        init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.*));
                        ret = true;
                    }
                }
            },
            .key => |ke| {
                if (ke.action == .down or ke.action == .repeat) {
                    switch (ke.code) {
                        .left, .down => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.* - 1));
                            ret = true;
                        },
                        .right, .up => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.* + 1));
                            ret = true;
                        },
                        else => {},
                    }
                }
            },
            .text => |te| {
                switch (te.action) {
                    .value => |set| blk: {
                        e.handle(@src(), b.data());
                        const value: T = std.fmt.parseInt(T, set.txt, 10) catch break :blk;
                        init_opts.fraction.* = std.math.clamp(value, init_opts.min, init_opts.max);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    const perc_int: T = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.*));
    const perc: f32 = @as(f32, @floatFromInt(perc_int - init_opts.min)) / @as(f32, @floatFromInt(init_opts.max - init_opts.min));

    var part = trackrs.r;
    switch (init_opts.dir) {
        .horizontal => part.w *= perc,
        .vertical => {
            const h = part.h * (1 - perc);
            part.y += h;
            part.h = trackrs.r.h - h;
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = init_opts.color_bar orelse dvui.themeGet().color(.highlight, .fill), .fade = 1.0 });
    }

    switch (init_opts.dir) {
        .horizontal => {
            part.x = part.x + part.w;
            part.w = trackrs.r.w - part.w;
        },
        .vertical => {
            part = trackrs.r;
            part.h *= (1 - perc);
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = options.color(.fill), .fade = 1.0 });
    }

    const knobRect = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = (br.w - knobsize) * perc, .w = knobsize, .h = knobsize },
        .vertical => dvui.Rect{ .y = (br.h - knobsize) * (1 - perc), .w = knobsize, .h = knobsize },
    };

    const hover_t = dvui.hoverFade(b.data().id, hovered);
    const fill_color: dvui.Color = if (dvui.captured(b.data().id))
        options.color(.fill_press)
    else
        options.color(.fill).lerp(options.color(.fill_hover), hover_t);

    var knob: dvui.BoxWidget = undefined;
    knob.init(@src(), .{ .dir = .horizontal }, .{
        .rect = knobRect,
        .padding = .{},
        .margin = .{},
        .background = true,
        .border = dvui.Rect.all(1),
        .corners = .all(100),
        .color_fill = fill_color,
    });

    knob.drawBackground();
    if (b.data().id == dvui.focusedWidgetId()) {
        knob.data().focusBorder();
    }
    knob.deinit();

    if (ret) {
        dvui.refresh(null, @src(), b.data().id);
    }

    return ret;
}

pub fn SliderFloatInitOptions(comptime T: type) type {
    return struct {
        fraction: *T,
        min: T,
        max: T,

        dir: dvui.enums.Direction = .horizontal,

        /// Color of the left/top side of the slider.  If null, uses Theme.highlight.fill
        color_bar: ?dvui.Color = null,
    };
}

pub fn sliderFloat(src: std.builtin.SourceLocation, comptime T: type, init_opts: SliderFloatInitOptions(T), opts: dvui.Options) bool {
    std.debug.assert(init_opts.min <= init_opts.max);
    if (init_opts.fraction.* < init_opts.min) {
        init_opts.fraction.* = init_opts.min;
    }
    if (init_opts.fraction.* > init_opts.max) {
        init_opts.fraction.* = init_opts.max;
    }

    const options = dvui.slider_defaults.override(opts);

    var b = dvui.box(src, .{ .dir = init_opts.dir }, options);
    defer b.deinit();

    if (b.data().accesskit_node()) |ak_node| {
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.focus);
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.set_value);
        dvui.AccessKit.nodeSetOrientation(ak_node, switch (init_opts.dir) {
            .vertical => dvui.AccessKit.Orientation.vertical,
            .horizontal => dvui.AccessKit.Orientation.horizontal,
        });
        dvui.AccessKit.nodeSetNumericValue(ak_node, init_opts.fraction.*);
        dvui.AccessKit.nodeSetMinNumericValue(ak_node, init_opts.min);
        dvui.AccessKit.nodeSetMaxNumericValue(ak_node, init_opts.max);
        dvui.AccessKit.nodeSetNumericValueStep(ak_node, 1);
        dvui.AccessKit.nodeSetNumericValueJump(ak_node, 10);
    }

    dvui.tabIndexSet(b.data().id, options.tab_index, b.data().rectScale().r);

    var hovered: bool = false;
    var ret = false;

    const br = b.data().contentRect();
    const knobsize = @min(br.w, br.h);
    const track = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = knobsize / 2, .y = br.h / 2 - 2, .w = br.w - knobsize, .h = 4 },
        .vertical => dvui.Rect{ .x = br.w / 2 - 2, .y = knobsize / 2, .w = 4, .h = br.h - knobsize },
    };

    const trackrs = b.widget().screenRectScale(track);

    const rs = b.data().contentRectScale();
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = b.data().id, .r = rs.r }))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                var p: ?dvui.Point.Physical = null;
                if (me.action == .focus) {
                    e.handle(@src(), b.data());
                    dvui.focusWidget(b.data().id, null, e.num);
                } else if (me.action == .press and me.button.pointer()) {
                    // capture
                    dvui.captureMouse(b.data(), e.num);
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .release and me.button.pointer()) {
                    // stop capture
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    e.handle(@src(), b.data());
                } else if (me.action == .motion and dvui.captured(b.data().id)) {
                    // handle only if we have capture
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .position) {
                    dvui.cursorSet(.arrow);
                    hovered = true;
                }

                if (p) |pp| {
                    var min: f32 = undefined;
                    var max: f32 = undefined;
                    switch (init_opts.dir) {
                        .horizontal => {
                            min = trackrs.r.x;
                            max = trackrs.r.x + trackrs.r.w;
                        },
                        .vertical => {
                            min = 0;
                            max = trackrs.r.h;
                        },
                    }

                    if (max > min) {
                        const v = if (init_opts.dir == .horizontal) pp.x else (trackrs.r.y + trackrs.r.h - pp.y);
                        const perc = (v - min) / (max - min);
                        const perc_t: T = @floatCast(perc);
                        init_opts.fraction.* = init_opts.min + perc_t * (init_opts.max - init_opts.min);
                        init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.*));
                        ret = true;
                    }
                }
            },
            .key => |ke| {
                if (ke.action == .down or ke.action == .repeat) {
                    switch (ke.code) {
                        .left, .down => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.* - 1));
                            ret = true;
                        },
                        .right, .up => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.* + 1));
                            ret = true;
                        },
                        else => {},
                    }
                }
            },
            .text => |te| {
                switch (te.action) {
                    .value => |set| blk: {
                        e.handle(@src(), b.data());
                        const value: T = std.fmt.parseFloat(T, set.txt) catch break :blk;
                        init_opts.fraction.* = std.math.clamp(value, init_opts.min, init_opts.max);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    const perc: f32 = @floatCast(@max(0, @min(1, (init_opts.fraction.* - init_opts.min) / (init_opts.max - init_opts.min))));

    var part = trackrs.r;
    switch (init_opts.dir) {
        .horizontal => part.w *= perc,
        .vertical => {
            const h = part.h * (1 - perc);
            part.y += h;
            part.h = trackrs.r.h - h;
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = init_opts.color_bar orelse dvui.themeGet().color(.highlight, .fill), .fade = 1.0 });
    }

    switch (init_opts.dir) {
        .horizontal => {
            part.x = part.x + part.w;
            part.w = trackrs.r.w - part.w;
        },
        .vertical => {
            part = trackrs.r;
            part.h *= (1 - perc);
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = options.color(.fill), .fade = 1.0 });
    }

    const knobRect = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = (br.w - knobsize) * perc, .w = knobsize, .h = knobsize },
        .vertical => dvui.Rect{ .y = (br.h - knobsize) * (1 - perc), .w = knobsize, .h = knobsize },
    };

    const hover_t = dvui.hoverFade(b.data().id, hovered);
    const fill_color: dvui.Color = if (dvui.captured(b.data().id))
        options.color(.fill_press)
    else
        options.color(.fill).lerp(options.color(.fill_hover), hover_t);

    var knob: dvui.BoxWidget = undefined;
    knob.init(@src(), .{ .dir = .horizontal }, .{
        .rect = knobRect,
        .padding = .{},
        .margin = .{},
        .background = true,
        .border = dvui.Rect.all(1),
        .corners = .all(100),
        .color_fill = fill_color,
    });

    knob.drawBackground();
    if (b.data().id == dvui.focusedWidgetId()) {
        knob.data().focusBorder();
    }
    knob.deinit();

    if (ret) {
        dvui.refresh(null, @src(), b.data().id);
    }

    return ret;
}
pub fn sliderFloatLog(src: std.builtin.SourceLocation, comptime T: type, init_opts: SliderFloatInitOptions(T), opts: dvui.Options) bool {
    std.debug.assert(init_opts.min <= init_opts.max);
    std.debug.assert(std.math.floatEps(T) <= init_opts.min);
    if (init_opts.fraction.* < init_opts.min) {
        init_opts.fraction.* = init_opts.min;
    }
    if (init_opts.fraction.* > init_opts.max) {
        init_opts.fraction.* = init_opts.max;
    }

    const options = dvui.slider_defaults.override(opts);

    var b = dvui.box(src, .{ .dir = init_opts.dir }, options);
    defer b.deinit();

    if (b.data().accesskit_node()) |ak_node| {
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.focus);
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.set_value);
        dvui.AccessKit.nodeSetOrientation(ak_node, switch (init_opts.dir) {
            .vertical => dvui.AccessKit.Orientation.vertical,
            .horizontal => dvui.AccessKit.Orientation.horizontal,
        });
        dvui.AccessKit.nodeSetNumericValue(ak_node, init_opts.fraction.*);
        dvui.AccessKit.nodeSetMinNumericValue(ak_node, init_opts.min);
        dvui.AccessKit.nodeSetMaxNumericValue(ak_node, init_opts.max);
        // dvui.AccessKit.nodeSetNumericValueStep(ak_node, 1);
        // dvui.AccessKit.nodeSetNumericValueJump(ak_node, 10);
    }

    dvui.tabIndexSet(b.data().id, options.tab_index, b.data().rectScale().r);

    var hovered: bool = false;
    var ret = false;

    const br = b.data().contentRect();
    const knobsize = @min(br.w, br.h);
    const track = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = knobsize / 2, .y = br.h / 2 - 2, .w = br.w - knobsize, .h = 4 },
        .vertical => dvui.Rect{ .x = br.w / 2 - 2, .y = knobsize / 2, .w = 4, .h = br.h - knobsize },
    };

    const trackrs = b.widget().screenRectScale(track);

    const rs = b.data().contentRectScale();
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = b.data().id, .r = rs.r }))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                var p: ?dvui.Point.Physical = null;
                if (me.action == .focus) {
                    e.handle(@src(), b.data());
                    dvui.focusWidget(b.data().id, null, e.num);
                } else if (me.action == .press and me.button.pointer()) {
                    // capture
                    dvui.captureMouse(b.data(), e.num);
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .release and me.button.pointer()) {
                    // stop capture
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    e.handle(@src(), b.data());
                } else if (me.action == .motion and dvui.captured(b.data().id)) {
                    // handle only if we have capture
                    e.handle(@src(), b.data());
                    p = me.p;
                } else if (me.action == .position) {
                    dvui.cursorSet(.arrow);
                    hovered = true;
                }

                if (p) |pp| {
                    var min: f32 = undefined;
                    var max: f32 = undefined;
                    switch (init_opts.dir) {
                        .horizontal => {
                            min = trackrs.r.x;
                            max = trackrs.r.x + trackrs.r.w;
                        },
                        .vertical => {
                            min = 0;
                            max = trackrs.r.h;
                        },
                    }

                    if (max > min) {
                        const v = if (init_opts.dir == .horizontal) pp.x else (trackrs.r.y + trackrs.r.h - pp.y);
                        const perc = (v - min) / (max - min);
                        const perc_t: T = @floatCast(perc);
                        init_opts.fraction.* = std.math.exp2(std.math.log2(init_opts.min) + perc_t * (std.math.log2(init_opts.max) - std.math.log2(init_opts.min)));
                        init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, init_opts.fraction.*));
                        ret = true;
                    }
                }
            },
            .key => |ke| {
                if (ke.action == .down or ke.action == .repeat) {
                    switch (ke.code) {
                        .left, .down => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, std.math.exp2(std.math.log2(init_opts.fraction.*) - 1)));
                            ret = true;
                        },
                        .right, .up => {
                            e.handle(@src(), b.data());
                            init_opts.fraction.* = @max(init_opts.min, @min(init_opts.max, std.math.exp2(std.math.log2(init_opts.fraction.*) + 1)));
                            ret = true;
                        },
                        else => {},
                    }
                }
            },
            .text => |te| {
                switch (te.action) {
                    .value => |set| blk: {
                        e.handle(@src(), b.data());
                        const value: T = std.fmt.parseFloat(T, set.txt) catch break :blk;
                        init_opts.fraction.* = std.math.clamp(value, init_opts.min, init_opts.max);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    const perc: f32 = @floatCast(@max(0, @min(1, (std.math.log2(init_opts.fraction.*) - std.math.log2(init_opts.min)) / (std.math.log2(init_opts.max) - std.math.log2(init_opts.min)))));

    var part = trackrs.r;
    switch (init_opts.dir) {
        .horizontal => part.w *= perc,
        .vertical => {
            const h = part.h * (1 - perc);
            part.y += h;
            part.h = trackrs.r.h - h;
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = init_opts.color_bar orelse dvui.themeGet().color(.highlight, .fill), .fade = 1.0 });
    }

    switch (init_opts.dir) {
        .horizontal => {
            part.x = part.x + part.w;
            part.w = trackrs.r.w - part.w;
        },
        .vertical => {
            part = trackrs.r;
            part.h *= (1 - perc);
        },
    }
    if (b.data().visible()) {
        part.fill(options.cornersGet().scale(trackrs.s, dvui.CornerRect.Physical), .{ .color = options.color(.fill), .fade = 1.0 });
    }

    const knobRect = switch (init_opts.dir) {
        .horizontal => dvui.Rect{ .x = (br.w - knobsize) * perc, .w = knobsize, .h = knobsize },
        .vertical => dvui.Rect{ .y = (br.h - knobsize) * (1 - perc), .w = knobsize, .h = knobsize },
    };

    const hover_t = dvui.hoverFade(b.data().id, hovered);
    const fill_color: dvui.Color = if (dvui.captured(b.data().id))
        options.color(.fill_press)
    else
        options.color(.fill).lerp(options.color(.fill_hover), hover_t);

    var knob: dvui.BoxWidget = undefined;
    knob.init(@src(), .{ .dir = .horizontal }, .{
        .rect = knobRect,
        .padding = .{},
        .margin = .{},
        .background = true,
        .border = dvui.Rect.all(1),
        .corners = .all(100),
        .color_fill = fill_color,
    });

    knob.drawBackground();
    if (b.data().id == dvui.focusedWidgetId()) {
        knob.data().focusBorder();
    }
    knob.deinit();

    if (ret) {
        dvui.refresh(null, @src(), b.data().id);
    }

    return ret;
}

pub fn simpleRadio(
    src: std.builtin.SourceLocation,
    comptime T: type,
    value: *T,
    dir: dvui.enums.Direction,
) bool {
    if (@typeInfo(T) != .@"enum") {
        @compileError("Must be enum");
    }
    var group = dvui.radioGroup(src, .{}, .{});
    defer group.deinit();

    var box = dvui.box(@src(), .{ .dir = dir }, .{});
    defer box.deinit();

    var changed: bool = false;

    inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        if (dvui.radio(@src(), value.* == @as(T, @enumFromInt(field.value)), field.name, .{ .id_extra = i })) {
            value.* = @enumFromInt(field.value);
            changed = true;
        }
    }

    return changed;
}

pub fn simpleSliderEntryFloat(src: std.builtin.SourceLocation, comptime T: type, label: []const u8, slider_opts: SliderFloatInitOptions(T)) void {
    var hbox = dvui.box(src, .{ .dir = .horizontal }, .{});
    defer hbox.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .gravity_y = 0.5,
    });
    _ = sliderFloat(
        @src(),
        T,
        slider_opts,
        .{
            .min_size_content = .{ .w = 200, .h = 20 },
            .gravity_y = 0.5,
        },
    );
    _ = dvui.textEntryNumber(
        @src(),
        T,
        .{
            .min = slider_opts.min,
            .max = slider_opts.max,
            .value = slider_opts.fraction,
        },
        .{ .gravity_y = 0.5, .max_size_content = .{ .h = 60, .w = 60 } },
    );
}

pub fn simpleSliderEntryFloatLog(src: std.builtin.SourceLocation, comptime T: type, label: []const u8, slider_opts: SliderFloatInitOptions(T)) void {
    var hbox = dvui.box(src, .{ .dir = .horizontal }, .{});
    defer hbox.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .gravity_y = 0.5,
    });
    _ = sliderFloatLog(
        @src(),
        T,
        slider_opts,
        .{
            .min_size_content = .{ .w = 200, .h = 20 },
            .gravity_y = 0.5,
        },
    );
    _ = dvui.textEntryNumber(
        @src(),
        T,
        .{
            .min = slider_opts.min,
            .max = slider_opts.max,
            .value = slider_opts.fraction,
        },
        .{ .gravity_y = 0.5, .max_size_content = .{ .h = 60, .w = 60 } },
    );
}

pub fn simpleSliderEntryInt(src: std.builtin.SourceLocation, comptime T: type, label: []const u8, slider_opts: SliderIntInitOptions(T)) void {
    var hbox = dvui.box(src, .{ .dir = .horizontal }, .{});
    defer hbox.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{});
    _ = sliderInt(
        @src(),
        T,
        slider_opts,
        .{
            .min_size_content = .{ .w = 200, .h = 20 },
            .gravity_y = 0.5,
        },
    );
    _ = dvui.textEntryNumber(
        @src(),
        T,
        .{
            .min = slider_opts.min,
            .max = slider_opts.max,
            .value = slider_opts.fraction,
        },
        .{ .gravity_y = 0.5, .max_size_content = .{ .h = 60, .w = 60 } },
    );
}
