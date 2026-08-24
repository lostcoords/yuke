const std = @import("std");
const vaxis = @import("vaxis");

pub const Cell = vaxis.Cell;
pub const Style = vaxis.Style;
pub const Screen = vaxis.Screen;
pub const Window = vaxis.Window;
pub const Parser = vaxis.Parser;

test "vaxis sans-io cores are available" {
    _ = Cell;
    _ = Style;
    _ = Screen;
    _ = Window;
    _ = Parser;
}
