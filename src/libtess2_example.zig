const std = @import("std");

pub const dvui = @import("dvui");
pub const libtess2 = @import("libtess2");

pub const math = @import("math.zig");
const Transform = math.Transform;
const BBox = math.BBox;
const FloatPair = math.FloatPair;

const sentinel: FloatPair = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
const ContourIterator = struct {
    path: []const FloatPair,
    start: usize = 0,
    end: usize = 0,

    fn next(self: *ContourIterator) ?[]const FloatPair {
        if (self.start >= self.path.len) {
            return null;
        }
        defer {
            self.start = self.end + 1;
            self.end = self.start;
        }
        while (self.end < self.path.len) {
            if (self.path[self.end].eq(sentinel)) {
                break;
            } else {
                self.end += 1;
            }
        }
        return self.path[self.start..self.end];
    }
};

pub const dvui_utils = @import("dvui_utils.zig");

pub const Context = struct {
    const RenderOptions = struct {
        path_width: f32 = 2,
        use_arrows: bool = true,
        arrow_tip_size: f32 = 10,
        arrow_angle_degrees: f32 = 30,

        polygon_color: dvui.Color.HSV = .{ .h = 240, .s = 1, .v = 0.6 },
        hovered_polygon_color: dvui.Color.HSV = .{ .h = 300, .s = 1, .v = 0.8 },
        neighbour_triangle_color: dvui.Color.HSV = .{ .h = 270, .s = 1, .v = 0.6 },
    };
    const TesselationOptions = struct {
        element_type: libtess2.ElementType = .polygons,
        winding_rule: libtess2.WindingRule = .nonzero,
        cdt: bool = true,
        use_boundaries_output_as_input: bool = false,
        triangulation_only: bool = false,
        poly_size: usize = 4,
    };

    path: std.ArrayList(FloatPair) = .empty,
    boundary_path: std.ArrayList(FloatPair) = .empty,
    path_finalized: bool = false,

    dvui_triangles: dvui.Triangles = .empty,
    triangles_builder: dvui_utils.Triangles.Builder = .{},

    tesselation_count_mb: ?usize = null,
    mouse_world_pos_mb: ?FloatPair = null,

    render_options: RenderOptions = .{},
    tesselation_options: TesselationOptions = .{},

    pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
        self.dvui_triangles.deinit(gpa);
        self.triangles_builder.deinit(gpa);
        self.path.deinit(gpa);
        self.boundary_path.deinit(gpa);
    }

    pub fn gui_frame(self: *Context, gpa: std.mem.Allocator) !bool {
        var sa = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer sa.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .all(20) });
        {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5 });
            defer vbox.deinit();

            try frame(self, gpa);
            try footer(self, gpa);
            tesselationOptions(self);
            renderOptions(self);
        }
        for (dvui.events()) |*e| {
            // assume we only have a single window
            if (e.evt == .window and e.evt.window.action == .close) return false;
            if (e.evt == .app and e.evt.app.action == .quit) return false;
        }
        return true;
    }

    fn frame(self: *Context, gpa: std.mem.Allocator) !void {
        self.reset();

        var wd = dvui.spacer(@src(), .{ .min_size_content = .all(512), .background = true, .color_fill = .gray });
        const old_rect = dvui.clip(wd.contentRectScale().rectToPhysical(wd.contentRect().justSize()));
        defer dvui.clipSet(old_rect);
        const drag = dvui.dataGetPtrDefault(null, wd.id, "drag_transform", dvui_utils.DragTransformConstrained, .{
            .transform = .{ .scaling_factor = 1 },
            .max_zoom_mult = 600.0,
            .source_bbox = .{
                .min_x = 0,
                .max_x = 512,
                .min_y = 0,
                .max_y = 512,
            },
        });
        drag.processEvents(wd);

        const events = dvui.events();
        const pos_event = &events[events.len - 1];
        if (dvui.eventMatch(pos_event, .{ .id = wd.id, .r = wd.contentRectScale().r })) {
            self.mouse_world_pos_mb = dvui_utils.mouseWorldPos(pos_event.evt.mouse.p, wd.contentRectScale(), drag.transform);
        }

        for (dvui.events()) |*e| {
            if (!dvui.eventMatch(e, .{ .id = wd.id, .r = wd.contentRectScale().r })) {
                continue;
            }
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button == .left) {
                        const mouse_world_pos = dvui_utils.mouseWorldPos(me.p, wd.contentRectScale(), drag.transform);
                        try self.path.append(gpa, mouse_world_pos);
                    } else if (me.action == .press and me.button == .middle) {
                        if (self.path.items.len > 2 and !self.path.items[self.path.items.len - 1].eq(sentinel) and !self.path.items[self.path.items.len - 2].eq(sentinel) and !self.path.items[self.path.items.len - 3].eq(sentinel)) {
                            try self.path.append(gpa, sentinel);
                        }
                    }
                },
                else => {},
            }
        }
        if (!self.path_finalized) {
            try self.paintPath(gpa);
        } else {
            switch (self.tesselation_options.element_type) {
                .polygons => {
                    if (self.tesselation_options.triangulation_only) {
                        try self.paintTriangulationPoly(gpa);
                    } else {
                        try self.paintTesselationPoly(gpa);
                    }
                },
                .connected_polygons => {
                    if (self.tesselation_options.triangulation_only) {
                        try self.paintTriangulationPolyNeighbours(gpa);
                    } else {
                        try self.paintTesselationPolyNeighbours(gpa);
                    }
                },
                .boundary_contours => {
                    if (self.tesselation_options.triangulation_only) {
                        try self.paintTriangulationBoundaries(gpa);
                    } else {
                        try self.paintTesselationBoundaries(gpa);
                    }
                },
            }
        }
        try self.render(gpa, wd.contentRectScale(), drag.transform);
    }

    fn footer(self: *Context, gpa: std.mem.Allocator) !void {
        dvui.labelNoFmt(@src(), "Use Right Mouse to Drag and Mouse Wheel to Zoom", .{}, .{});
        dvui.labelNoFmt(@src(), "Left-click: Add a Point.\nMiddle-click: Close the Path.", .{}, .{});
        if (self.tesselation_count_mb) |n| {
            dvui.label(@src(), "Tesselated into {d} polygons. Try to hover over them.", .{n}, .{});
        } else {
            dvui.label(@src(), "", .{}, .{});
        }
        dvui.label(@src(), "Rendering {d} Vertices and {d} Indices", .{ self.triangles_builder.vertexes.items.len, self.triangles_builder.indices.items.len }, .{});
        {
            var button_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer button_hbox.deinit();
            if (!self.path_finalized) {
                if (dvui.button(@src(), "Reset Path", .{}, .{})) {
                    self.path.clearRetainingCapacity();
                }
                if (dvui.button(@src(), "Close Path", .{}, .{})) {
                    if (self.path.items.len > 2 and !self.path.items[self.path.items.len - 1].eq(sentinel) and !self.path.items[self.path.items.len - 2].eq(sentinel) and !self.path.items[self.path.items.len - 3].eq(sentinel)) {
                        try self.path.append(gpa, sentinel);
                    }
                }
                if (dvui.button(@src(), "Finalize Path", .{}, .{})) {
                    if (self.path.items.len > 3 and std.meta.eql(self.path.getLast(), sentinel)) {
                        self.path_finalized = true;
                    }
                }
            } else {
                if (dvui.button(@src(), "Back To Path Editing", .{}, .{})) {
                    self.path_finalized = false;
                }
            }
        }
    }

    fn renderOptions(self: *Context) void {
        if (dvui.expander(@src(), "Render Options", .{}, .{})) {
            var box = dvui.box(@src(), .{}, .{ .border = .all(2) });
            defer box.deinit();
            dvui_utils.simpleSliderEntryFloatLog(@src(), f32, "Line Width", .{
                .fraction = &self.render_options.path_width,
                .min = 0.01,
                .max = 10,
            });
            self.render_options.path_width = self.render_options.path_width;
            _ = dvui.checkbox(@src(), &self.render_options.use_arrows, "Use Arrows", .{});
            if (self.render_options.use_arrows) {
                dvui_utils.simpleSliderEntryFloat(@src(), f32, "Arrow Tip Size", .{
                    .fraction = &self.render_options.arrow_tip_size,
                    .min = 1.0,
                    .max = 20.0,
                });
                dvui_utils.simpleSliderEntryFloat(@src(), f32, "Arrow Tip Angle", .{
                    .fraction = &self.render_options.arrow_angle_degrees,
                    .min = 0.0,
                    .max = 90.0,
                });
            }
            {
                var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{});
                defer vbox.deinit();

                dvui.labelNoFmt(@src(), "Polygon Color", .{}, .{});
                _ = dvui.colorPicker(@src(), .{ .hsv = &self.render_options.polygon_color, .sliders = .hsv }, .{});

                dvui.labelNoFmt(@src(), "Hovered Polygon Color", .{}, .{});
                _ = dvui.colorPicker(@src(), .{ .hsv = &self.render_options.hovered_polygon_color, .sliders = .hsv }, .{});

                dvui.labelNoFmt(@src(), "Neighbouring Hovered Polygon Color", .{}, .{});
                _ = dvui.colorPicker(@src(), .{ .hsv = &self.render_options.neighbour_triangle_color, .sliders = .hsv }, .{});
            }
        }
    }

    fn tesselationOptions(self: *Context) void {
        if (dvui.expander(@src(), "Tesselation Options", .{}, .{})) {
            var box = dvui.box(@src(), .{}, .{ .border = .all(2) });
            defer box.deinit();

            _ = dvui_utils.simpleRadio(@src(), libtess2.ElementType, &self.tesselation_options.element_type, .horizontal);
            dvui.labelNoFmt(@src(), "Winding Rule", .{}, .{});
            _ = dvui_utils.simpleRadio(@src(), libtess2.WindingRule, &self.tesselation_options.winding_rule, .horizontal);
            _ = dvui.checkbox(@src(), &self.tesselation_options.cdt, "Constained Delanuay Triangulation", .{});
            // _ = dvui.checkbox(@src(), &self.tesselation_options.rc, "Reverse Contours", .{});
            _ = dvui.checkbox(@src(), &self.tesselation_options.use_boundaries_output_as_input, "Use Boundaries Output as Input for Tesselation", .{});
            _ = dvui.checkbox(@src(), &self.tesselation_options.triangulation_only, "Triangulation Only", .{});
            if (!self.tesselation_options.triangulation_only) {
                dvui_utils.simpleSliderEntryInt(@src(), usize, "Polygon Size", .{
                    .fraction = &self.tesselation_options.poly_size,
                    .min = 3,
                    .max = 10,
                });
            }
        }
    }

    fn paintEdge(self: *Context, gpa: std.mem.Allocator, p1: FloatPair, p2: FloatPair) !void {
        if (self.render_options.use_arrows) {
            try dvui_utils.addArrow(
                &self.triangles_builder,
                gpa,
                p1,
                p2,
                self.render_options.path_width,
                self.render_options.arrow_tip_size * self.render_options.path_width,
                std.math.degreesToRadians(self.render_options.arrow_angle_degrees),
                .black,
            );
        } else {
            try dvui_utils.addLine(
                &self.triangles_builder,
                gpa,
                p1,
                p2,
                self.render_options.path_width,
                .black,
            );
        }
    }

    fn paintLine(self: *Context, gpa: std.mem.Allocator, p1: FloatPair, p2: FloatPair) !void {
        try dvui_utils.addLine(
            &self.triangles_builder,
            gpa,
            p1,
            p2,
            self.render_options.path_width,
            .black,
        );
    }

    fn paintBox(self: *Context, gpa: std.mem.Allocator, point: FloatPair) !void {
        try dvui_utils.addBox(
            &self.triangles_builder,
            gpa,
            point,
            self.render_options.path_width,
            .black,
        );
    }

    fn paintPath(self: *Context, gpa: std.mem.Allocator) !void {
        var first_point: ?FloatPair = null;
        var prev_point: ?FloatPair = null;
        var start: bool = true;
        for (self.path.items) |pos| {
            if (first_point == null) {
                first_point = pos;
                prev_point = pos;
                start = true;
            } else {
                if (!std.meta.eql(pos, sentinel)) {
                    try self.paintEdge(
                        gpa,
                        prev_point.?,
                        pos,
                    );
                    prev_point = pos;
                } else {
                    try self.paintEdge(
                        gpa,
                        prev_point.?,
                        first_point.?,
                    );
                    prev_point = null;
                    first_point = null;
                }
                start = false;
            }
        }
        if (start and prev_point != null) {
            try self.paintBox(gpa, prev_point.?);
        }
    }

    fn activePath(self: *Context, gpa: std.mem.Allocator) !?std.ArrayList(FloatPair) {
        if (self.tesselation_options.use_boundaries_output_as_input) {
            self.boundary_path.clearRetainingCapacity();

            var tess = try libtess2.TesselatorEx(.@"2", 3).init(&gpa, .{});
            defer tess.deinit();
            tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

            var contour_iter: ContourIterator = .{ .path = self.path.items };
            while (contour_iter.next()) |contour| {
                try tess.addContourFromSlice(FloatPair, contour, 0);
            }

            const result = try tess.tesselateBoundaries(self.tesselation_options.winding_rule, null) orelse return null;
            for (result.boundaries) |boundary| {
                const contour = boundary.subslice([2]f32, result.vertices);
                try self.boundary_path.appendSlice(gpa, @ptrCast(contour));
                try self.boundary_path.append(gpa, sentinel);
            }
            return self.boundary_path;
        } else {
            return self.path;
        }
    }

    fn paintTriangulationPoly(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.TesselatorEx(.@"2", 3).init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContourFromSlice(FloatPair, contour, 0);
        }

        const result = try tess.tesselatePolygons(
            if (self.tesselation_options.use_boundaries_output_as_input) .nonzero else self.tesselation_options.winding_rule,
            null,
        ) orelse return;
        self.tesselation_count_mb = result.polygons.len;

        const vertex_start: dvui.Vertex.Index = @intCast(self.triangles_builder.vertexes.items.len);
        for (result.vertices) |v| {
            try self.triangles_builder.vertexes.append(gpa, .{
                .pos = @bitCast(v),
                .col = .fromColor(self.render_options.polygon_color.toColor()),
            });
        }

        for (result.polygons) |polygon| {
            var inside = false;

            if (self.mouse_world_pos_mb) |p| {
                var edge_iter = polygon.edgeIter();
                while (edge_iter.next()) |idx_pair| {
                    const p1: FloatPair = @bitCast(result.vertices[idx_pair[0]]);
                    const p2: FloatPair = @bitCast(result.vertices[idx_pair[1]]);

                    if (math.rayRightIntersectsEdge(p, p1, p2)) inside = !inside;
                }
            }
            const color_change: ?dvui.Color.HSV = if (!inside) null else self.render_options.hovered_polygon_color;

            var tri_iter = polygon.triangleIter();
            while (tri_iter.next()) |idx_tri| {
                const idx0: usize = idx_tri[0] + @as(usize, @intCast(vertex_start));
                const idx1: usize = idx_tri[1] + @as(usize, @intCast(vertex_start));
                const idx2: usize = idx_tri[2] + @as(usize, @intCast(vertex_start));
                if (color_change) |color| {
                    try self.triangles_builder.addOneTriangle(
                        gpa,
                        @bitCast(result.vertices[idx0]),
                        @bitCast(result.vertices[idx1]),
                        @bitCast(result.vertices[idx2]),
                        .fromColor(color.toColor()),
                    );
                } else {
                    try self.triangles_builder.indices.appendSlice(gpa, &.{ @intCast(idx0), @intCast(idx1), @intCast(idx2) });
                }
            }

            var edge_iter2 = polygon.edgeIter();
            while (edge_iter2.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices[idx_pair[1]]);

                try self.paintLine(gpa, p1, p2);
            }
        }
    }

    fn paintTriangulationPolyNeighbours(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.TesselatorEx(.@"2", 3).init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContourFromSlice(
                FloatPair,
                @ptrCast(contour),
                0,
            );
        }
        const result = try tess.tesselateConnectedPolygons(
            if (self.tesselation_options.use_boundaries_output_as_input) .nonzero else self.tesselation_options.winding_rule,
            null,
        ) orelse return;
        self.tesselation_count_mb = result.connected_polygons.len;

        var selected: ?usize = null;
        var neighbours: [3]c_int = undefined;

        if (self.mouse_world_pos_mb) |p| {
            for (result.connected_polygons, 0..) |c_polygon, i| {
                var inside = false;
                var edge_iter = c_polygon.polygon.edgeIter();
                while (edge_iter.next()) |idx_pair| {
                    const p1: FloatPair = @bitCast(result.vertices[idx_pair[0]]);
                    const p2: FloatPair = @bitCast(result.vertices[idx_pair[1]]);

                    if (math.rayRightIntersectsEdge(p, p1, p2)) inside = !inside;
                }
                if (inside) {
                    neighbours = c_polygon.neighbours;
                    selected = i;
                    break;
                }
            }
        }

        const vertex_start: dvui.Vertex.Index = @intCast(self.triangles_builder.vertexes.items.len);
        for (result.vertices) |v| {
            try self.triangles_builder.vertexes.append(gpa, .{ .pos = @bitCast(v), .col = .fromColor(self.render_options.polygon_color.toColor()) });
        }

        for (result.connected_polygons, 0..) |connected_polygon, i| {
            var color_change: ?dvui.Color.HSV = null;

            if (selected) |sel| {
                if (sel == i) color_change = self.render_options.hovered_polygon_color;
                for (neighbours) |n| {
                    if (libtess2.wrapIndexMb(n) == i) {
                        color_change = self.render_options.neighbour_triangle_color;
                    }
                }
            }
            var tri_iter = connected_polygon.polygon.triangleIter();
            while (tri_iter.next()) |idx_tri| {
                const idx0: usize = idx_tri[0] + @as(usize, @intCast(vertex_start));
                const idx1: usize = idx_tri[1] + @as(usize, @intCast(vertex_start));
                const idx2: usize = idx_tri[2] + @as(usize, @intCast(vertex_start));
                if (color_change) |color| {
                    try self.triangles_builder.addOneTriangle(
                        gpa,
                        @bitCast(result.vertices[idx0]),
                        @bitCast(result.vertices[idx1]),
                        @bitCast(result.vertices[idx2]),
                        .fromColor(color.toColor()),
                    );
                } else {
                    try self.triangles_builder.indices.appendSlice(gpa, &.{
                        @intCast(idx0),
                        @intCast(idx1),
                        @intCast(idx2),
                    });
                }
            }

            var edge_iter = connected_polygon.polygon.edgeIter();
            while (edge_iter.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices[idx_pair[1]]);

                try self.paintLine(gpa, p1, p2);
            }
        }
    }

    fn paintTriangulationBoundaries(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.TesselatorEx(.@"2", 3).init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContourFromSlice(
                FloatPair,
                contour,
                0,
            );
        }

        const result = try tess.tesselateBoundaries(
            self.tesselation_options.winding_rule,
            null,
        ) orelse return;

        for (result.boundaries) |boundary| {
            var idx_pair_iter = boundary.pairIterator();
            while (idx_pair_iter.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices[idx_pair[1]]);
                try self.paintEdge(
                    gpa,
                    p1,
                    p2,
                );
            }
        }
    }

    fn paintTesselationPoly(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.Tesselator.init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContour(
                .@"2",
                @ptrCast(contour),
                @sizeOf([2]f32),
                contour.len,
            );
        }

        const result = try tess.tesselate(
            if (self.tesselation_options.use_boundaries_output_as_input) .nonzero else self.tesselation_options.winding_rule,
            .polygons,
            self.tesselation_options.poly_size,
            .@"2",
            null,
        ) orelse return;
        self.tesselation_count_mb = result.element_count;

        // Triangles
        const vertex_start: dvui.Vertex.Index = @intCast(self.triangles_builder.vertexes.items.len);

        for (0..result.vertex_count) |i| {
            try self.triangles_builder.vertexes.append(gpa, .{
                .pos = @bitCast(result.vertices2()[i]),
                .col = .fromColor(self.render_options.polygon_color.toColor()),
            });
        }

        var polygon_iter = result.polygonIterator();
        while (polygon_iter.next()) |polygon| {
            var inside = false;

            if (self.mouse_world_pos_mb) |p| {
                var edge_iter = polygon.edgeIter();
                while (edge_iter.next()) |idx_pair| {
                    const p1: FloatPair = @bitCast(result.vertices2()[idx_pair[0]]);
                    const p2: FloatPair = @bitCast(result.vertices2()[idx_pair[1]]);

                    if (math.rayRightIntersectsEdge(p, p1, p2)) inside = !inside;
                }
            }
            const color_change: ?dvui.Color.HSV = if (!inside) null else self.render_options.hovered_polygon_color;

            var tri_iter = polygon.triangleIter();
            while (tri_iter.next()) |idx_tri| {
                const idx0: usize = idx_tri[0] + @as(usize, @intCast(vertex_start));
                const idx1: usize = idx_tri[1] + @as(usize, @intCast(vertex_start));
                const idx2: usize = idx_tri[2] + @as(usize, @intCast(vertex_start));
                if (color_change) |color| {
                    try self.triangles_builder.addOneTriangle(
                        gpa,
                        @bitCast(result.vertices2()[idx0]),
                        @bitCast(result.vertices2()[idx1]),
                        @bitCast(result.vertices2()[idx2]),
                        .fromColor(color.toColor()),
                    );
                } else {
                    try self.triangles_builder.indices.appendSlice(gpa, &.{
                        @intCast(idx0),
                        @intCast(idx1),
                        @intCast(idx2),
                    });
                }
            }

            var edge_iter2 = polygon.edgeIter();
            while (edge_iter2.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices2()[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices2()[idx_pair[1]]);

                try self.paintLine(gpa, p1, p2);
            }
        }
    }

    fn paintTesselationPolyNeighbours(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.Tesselator.init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContour(
                .@"2",
                @ptrCast(contour),
                @sizeOf([2]f32),
                contour.len,
            );
        }
        const result = try tess.tesselate(
            if (self.tesselation_options.use_boundaries_output_as_input) .nonzero else self.tesselation_options.winding_rule,
            .connected_polygons,
            self.tesselation_options.poly_size,
            .@"2",
            null,
        ) orelse return;
        self.tesselation_count_mb = result.element_count;

        var selected: ?usize = null;
        var neighbours: []const c_int = undefined;

        if (self.mouse_world_pos_mb) |p| {
            var connected_polygon_iter = result.connectedPolygonIterator();
            var i: usize = 0;
            while (connected_polygon_iter.next()) |connected_polygon| : (i += 1) {
                var inside = false;
                var edge_iter = connected_polygon.polygon.edgeIter();
                while (edge_iter.next()) |idx_pair| {
                    const p1: FloatPair = @bitCast(result.vertices2()[idx_pair[0]]);
                    const p2: FloatPair = @bitCast(result.vertices2()[idx_pair[1]]);

                    if (math.rayRightIntersectsEdge(p, p1, p2)) inside = !inside;
                }
                if (inside) {
                    neighbours = connected_polygon.neighbours;
                    selected = i;
                    break;
                }
            }
        }
        const vertex_start: dvui.Vertex.Index = @intCast(self.triangles_builder.vertexes.items.len);
        for (result.vertices2()) |v| {
            try self.triangles_builder.vertexes.append(gpa, .{ .pos = @bitCast(v), .col = .fromColor(self.render_options.polygon_color.toColor()) });
        }

        var connected_polygon_iter = result.connectedPolygonIterator();
        var i: usize = 0;
        while (connected_polygon_iter.next()) |connected_polygon| : (i += 1) {
            var color_change: ?dvui.Color.HSV = null;

            if (selected) |sel| {
                if (sel == i) color_change = self.render_options.hovered_polygon_color;
                for (neighbours) |n| {
                    if (libtess2.wrapIndexMb(n) == i) {
                        color_change = self.render_options.neighbour_triangle_color;
                    }
                }
            }

            var tri_iter = connected_polygon.polygon.triangleIter();
            while (tri_iter.next()) |idx_tri| {
                const idx0: usize = idx_tri[0] + @as(usize, @intCast(vertex_start));
                const idx1: usize = idx_tri[1] + @as(usize, @intCast(vertex_start));
                const idx2: usize = idx_tri[2] + @as(usize, @intCast(vertex_start));
                if (color_change) |color| {
                    try self.triangles_builder.addOneTriangle(
                        gpa,
                        @bitCast(result.vertices2()[idx0]),
                        @bitCast(result.vertices2()[idx1]),
                        @bitCast(result.vertices2()[idx2]),
                        .fromColor(color.toColor()),
                    );
                } else {
                    try self.triangles_builder.indices.appendSlice(gpa, &.{
                        @intCast(idx0),
                        @intCast(idx1),
                        @intCast(idx2),
                    });
                }
            }
            
            var edge_iter = connected_polygon.polygon.edgeIter();
            while (edge_iter.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices2()[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices2()[idx_pair[1]]);

                try self.paintLine(gpa, p1, p2);
            }
        }
    }

    fn paintTesselationBoundaries(
        self: *Context,
        gpa: std.mem.Allocator,
    ) !void {
        const path = try self.activePath(gpa) orelse return;

        var tess = try libtess2.Tesselator.init(&gpa, .{});
        defer tess.deinit();
        tess.setOption(.constrained_delaunay_triangulation, @intFromBool(self.tesselation_options.cdt));

        var contour_iter: ContourIterator = .{ .path = path.items };
        while (contour_iter.next()) |contour| {
            try tess.addContour(
                .@"2",
                @ptrCast(contour),
                @sizeOf([2]f32),
                contour.len,
            );
        }

        const result = try tess.tesselate(
            self.tesselation_options.winding_rule,
            .boundary_contours,
            self.tesselation_options.poly_size,
            .@"2",
            null,
        ) orelse return;

        var boundary_iter = result.boundaryIterator();
        while (boundary_iter.next()) |boundary| {
            var pair_iter = boundary.pairIterator();
            while (pair_iter.next()) |idx_pair| {
                const p1: FloatPair = @bitCast(result.vertices2()[idx_pair[0]]);
                const p2: FloatPair = @bitCast(result.vertices2()[idx_pair[1]]);

                try self.paintEdge(
                    gpa,
                    p1,
                    p2,
                );
            }
        }
    }

    fn reset(self: *Context) void {
        self.mouse_world_pos_mb = null;
        self.tesselation_count_mb = null;

        self.triangles_builder.indices.clearRetainingCapacity();
        self.triangles_builder.vertexes.clearRetainingCapacity();
        self.triangles_builder.bbox = .degenerate;
    }

    fn render(self: *Context, gpa: std.mem.Allocator, wd_rs: dvui.RectScale, transform: Transform) !void {
        self.dvui_triangles.indices = try gpa.realloc(self.dvui_triangles.indices, self.triangles_builder.indices.items.len);
        self.dvui_triangles.vertexes = try gpa.realloc(self.dvui_triangles.vertexes, self.triangles_builder.vertexes.items.len);
        try dvui_utils.renderTriangles(
            self.triangles_builder.triangles(),
            &self.dvui_triangles,
            null,
            wd_rs,
            transform,
        );
    }
};
