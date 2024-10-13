const std = @import("std");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: Mutex,
        queue: std.DoublyLinkedList(T),

        const Self = @This();
        pub const Node = std.DoublyLinkedList(T).Node;
        pub fn init() Self {
            return Self{ .mutex = .{}, .queue = std.DoublyLinkedList(T){} };
        }
        pub fn append(self: *Self, element: *Node) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.append(element);
        }
        pub fn popOrNull(self: *Self) ?*Node {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.queue.pop()) |node| {
                return node;
            }
            return null;
        }
        pub fn createNode(self: *Self, allocator: std.mem.Allocator, val: T) !*Node {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = try allocator.create(Node);
            node.* = .{ .data = val };
            return node;
        }
    };
}
