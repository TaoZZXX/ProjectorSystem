// 单块 320x180 RGB332 帧缓存（57.6 KB，29 块 BSRAM）。
// 写入 cam_pclk 域，读取 pix_clk 域；读出时把 RGB332 展开成 RGB565 给显示用。
module camera_framebuffer (
    input  wire cam_pclk,
    input  wire cam_vsync,
    input  wire cam_href,
    input  wire [7:0] cam_data,
    input  wire cam_ready,
    input  wire pix_clk,
    input  wire video_frame_start,
    input  wire [8:0] read_x,
    input  wire [8:0] read_y,
    output wire [15:0] pixel_rgb565,
    output reg  frame_valid,
    output reg  [8:0] debug_lines,
    output reg  [8:0] debug_line_pixels,
    output reg  debug_captured,
    output reg  debug_published,
    output reg        cap_valid,
    output reg [15:0] cap_pix,
    output reg        cap_sof
);
    localparam integer PIXELS = 320 * 180;

    (* syn_ramstyle = "block_ram" *)
    reg [7:0] frame [0:PIXELS-1];
    reg [7:0] q;
    wire [15:0] read_addr = read_y * 16'd320 + read_x;

    always @(posedge pix_clk) q <= frame[read_addr];

    wire [4:0] r5 = {q[7:5], q[7:6]};
    wire [5:0] g6 = {q[4:2], q[4:3]};
    wire [4:0] b5 = {q[1:0], q[1:0], q[1]};
    assign pixel_rgb565 = {r5, g6, b5};

    reg published_toggle;
    reg acknowledged_toggle;
    reg [1:0] publish_sync;
    reg [1:0] ready_sync;
    reg [1:0] ack_sync;

    reg vs_prev, href_prev;
    reg [9:0] line_y;
    reg [9:0] pixel_x;
    reg byte_phase;
    reg [7:0] first_byte;
    reg capture_active;
    reg wr_en;
    reg [15:0] wr_addr;
    reg [7:0]  wr_data;

    wire cam_href_a = ~cam_href;

    always @(posedge cam_pclk) begin
        if (wr_en) frame[wr_addr] <= wr_data;
    end

    always @(posedge pix_clk) begin
        publish_sync <= {publish_sync[0], published_toggle};
        if (video_frame_start && publish_sync[1] != acknowledged_toggle) begin
            acknowledged_toggle <= publish_sync[1];
            frame_valid <= 1'b1;
        end
    end

    always @(posedge cam_pclk) begin
        ack_sync <= {ack_sync[0], acknowledged_toggle};
        ready_sync <= {ready_sync[0], cam_ready};
        vs_prev <= cam_vsync;
        href_prev <= cam_href_a;
        cap_sof <= (cam_vsync && !vs_prev);
        cap_valid <= 1'b0;
        wr_en <= 1'b0;
        if (cam_vsync) begin
            if (!vs_prev) begin
                debug_lines <= line_y[8:0];
                debug_captured <= capture_active;
                debug_published <= capture_active && line_y >= 10'd180;
            end
            if (!vs_prev && capture_active && line_y >= 10'd180)
                published_toggle <= ~published_toggle;
            capture_active <= 1'b0;
            line_y <= 10'd0;
            pixel_x <= 10'd0;
            byte_phase <= 1'b0;
        end else begin
            if (vs_prev && ready_sync[1] &&
                ack_sync[1] == published_toggle)
                capture_active <= 1'b1;
            if (href_prev && !cam_href_a) begin
                debug_line_pixels <= pixel_x[8:0];
                line_y <= line_y + 1'b1;
                pixel_x <= 10'd0;
                byte_phase <= 1'b0;
            end else if (cam_href_a) begin
                byte_phase <= ~byte_phase;
                if (!byte_phase) first_byte <= cam_data;
                else begin
                    pixel_x <= pixel_x + 1'b1;
                    cap_pix <= {first_byte, cam_data};
                    cap_valid <= 1'b1;
                    if (capture_active &&
                        pixel_x < 10'd320 && line_y < 10'd180) begin
                        wr_en <= 1'b1;
                        wr_addr <= line_y[8:0] * 16'd320 + {7'd0, pixel_x[8:0]};
                        wr_data <= {first_byte[7:5], first_byte[2:0],
                                    cam_data[4:3]};
                    end
                end
            end else byte_phase <= 1'b0;
        end
    end

    initial begin
        published_toggle = 1'b0;
        acknowledged_toggle = 1'b0;
        publish_sync = 2'b00;
        ready_sync = 2'b00;
        ack_sync = 2'b00;
        vs_prev = 1'b0;
        href_prev = 1'b0;
        line_y = 10'd0;
        pixel_x = 10'd0;
        byte_phase = 1'b0;
        first_byte = 8'd0;
        capture_active = 1'b0;
        wr_en = 1'b0;
        wr_addr = 16'd0;
        wr_data = 8'd0;
        frame_valid = 1'b0;
        debug_lines = 9'd0;
        debug_line_pixels = 9'd0;
        debug_captured = 1'b0;
        debug_published = 1'b0;
        cap_valid = 1'b0;
        cap_pix = 16'd0;
        cap_sof = 1'b0;
    end
endmodule
