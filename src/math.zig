const std = @import("std");
const dvui = @import("libtess2_example.zig").dvui;

pub fn rayRightIntersectsEdge(p: FloatPair, p1: FloatPair, p2: FloatPair) bool {
    if (@abs(p2.y - p1.y) < std.math.floatEps(f32)) {
        return false;
    }
    return ((p1.y > p.y) != (p2.y > p.y) and (p.x < (p2.x - p1.x) * (p.y - p1.y) / (p2.y - p1.y) + p1.x));
}


pub const FloatPair = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    pub fn eq(self: FloatPair, other: FloatPair) bool {
        return (self.x == other.x) and (self.y == other.y);
    }

    pub fn add(self: FloatPair, other: FloatPair) FloatPair {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: FloatPair, other: FloatPair) FloatPair {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn cross(self: FloatPair, other: FloatPair) f32 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn mulScalar(self: FloatPair, s: f32) FloatPair {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn negate(self: FloatPair) FloatPair {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub fn norm(self: FloatPair) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn rotate(self: FloatPair, radians: f32) FloatPair {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{
            .x = c * self.x + s * self.y,
            .y = -s * self.x + c * self.y,
        };
    }

    pub fn fromDvui(point: dvui.Point) FloatPair {
        return .{ .x = point.x, .y = point.y };
    }

    pub fn asDvui(self: FloatPair) dvui.Point {
        return .{ .x = self.x, .y = self.y };
    }
};

pub const Transform = struct {
    translation: FloatPair = .{},
    scaling_factor: f32 = 1.0,

    pub const identity: Transform = .{};

    pub fn inverse(self: Transform) Transform {
        if (self.scaling_factor == 0.0) {
            return .identity;
        } else {
            return .{ .translation = self.translation.mulScalar(1 / self.scaling_factor).negate(), .scaling_factor = 1 / self.scaling_factor };
        }
    }

    pub fn translate(self: Transform, dv: FloatPair) Transform {
        return .{ .translation = self.translation.add(dv), .scaling_factor = self.scaling_factor };
    }

    pub fn translate2(self: Transform, dx: f32, dy: f32) Transform {
        return .{ .translation = self.translation.add(.{ .x = dx, .y = dy }), .scaling_factor = self.scaling_factor };
    }

    pub fn scale(self: Transform, ds: f32) Transform {
        return .{ .translation = self.translation, .scaling_factor = self.scaling_factor * ds };
    }

    pub fn transformPoint(self: Transform, point: FloatPair) FloatPair {
        return .{ .x = self.scaling_factor * point.x + self.translation.x, .y = self.scaling_factor * point.y + self.translation.y };
    }
};

pub const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub const degenerate: BBox = .{
        .min_x = std.math.inf(f32),
        .min_y = std.math.inf(f32),
        .max_x = -std.math.inf(f32),
        .max_y = -std.math.inf(f32),
    };

    pub fn isValid(self: BBox) bool {
        return (self.min_x <= self.max_x) and (self.min_y <= self.max_y);
    }

    pub fn width(self: BBox) f32 {
        return self.max_x - self.min_x;
    }

    pub fn height(self: BBox) f32 {
        return self.max_y - self.min_y;
    }

    pub fn largeDiameter(self: BBox) f32 {
        return @max(self.width(), self.height());
    }

    pub fn smallDiameter(self: BBox) f32 {
        return @min(self.width(), self.height());
    }

    pub fn round(self: BBox) BBox {
        return .{
            .min_x = @floor(self.min_x),
            .max_x = @ceil(self.max_x),
            .min_y = @floor(self.min_y),
            .max_y = @ceil(self.max_y),
        };
    }

    pub fn expandToFitPoint(self: BBox, point: FloatPair) BBox {
        return .{
            .min_x = @min(self.min_x, point.x),
            .max_x = @max(self.max_x, point.x),
            .min_y = @min(self.min_y, point.y),
            .max_y = @max(self.max_y, point.y),
        };
    }

    pub fn expandByMargin(self: BBox, margin: f32) BBox {
        return .{
            .min_x = self.min_x - margin,
            .min_y = self.min_y - margin,
            .max_x = self.max_x + margin,
            .max_y = self.max_y + margin,
        };
    }

    pub fn expandToFitBBox(self: BBox, other: BBox) BBox {
        return .{
            .min_x = @min(self.min_x, other.min_x),
            .max_x = @max(self.max_x, other.max_x),
            .min_y = @min(self.min_y, other.min_y),
            .max_y = @max(self.max_y, other.max_y),
        };
    }

    pub fn translate(self: BBox, dv: FloatPair) BBox {
        return .{
            .min_x = self.min_x + dv.x,
            .max_x = self.max_x + dv.x,
            .min_y = self.min_y + dv.y,
            .max_y = self.max_y + dv.y,
        };
    }

    pub fn scale(self: BBox, s: f32) BBox {
        return .{
            .min_x = self.min_x * s,
            .max_x = self.max_x * s,
            .min_y = self.min_y * s,
            .max_y = self.max_y * s,
        };
    }

    pub fn transform(self: BBox, t: Transform) BBox {
        return self.scale(t.scaling_factor).translate(t.translation);
    }

    pub fn asDvuiRect(self: BBox) dvui.Rect {
        return .{
            .x = self.min_x,
            .y = self.min_y,
            .w = self.max_x - self.min_x,
            .h = self.max_y - self.min_y,
        };
    }

    pub fn fromDvuiRect(rect: dvui.Rect) BBox {
        return .{
            .min_x = rect.x,
            .min_y = rect.y,
            .max_x = rect.x + rect.w,
            .max_y = rect.y + rect.h,
        };
    }

    pub fn topLeft(self: BBox) FloatPair {
        return .{ .x = self.min_x, .y = self.min_y };
    }

    pub fn topRight(self: BBox) FloatPair {
        return .{ .x = self.max_x, .y = self.min_y };
    }

    pub fn bottomLeft(self: BBox) FloatPair {
        return .{ .x = self.min_x, .y = self.max_y };
    }

    pub fn bottomRight(self: BBox) FloatPair {
        return .{ .x = self.max_x, .y = self.max_y };
    }

    pub fn center(self: BBox) FloatPair {
        return .{ .x = (self.min_x + self.max_x) / 2, .y = (self.min_y + self.max_y) / 2 };
    }

    pub fn contains(self: BBox, p: FloatPair) bool {
        return (p.x >= self.min_x and p.x <= self.max_x and p.y >= self.min_y and p.y <= self.max_y);
    }
};
