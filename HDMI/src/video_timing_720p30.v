module video_timing_720p60 (
    input wire pix_clk,
    input wire rst_n,
    output reg [11:0] x,
    output reg [11:0] y,
    output wire de,
    output reg hsync,
    output reg vsync
);
    
always @(posedge pix_clk or negedge rst_n) begin
    if (!rst_n) begin
        x <= 0;
        y <= 0;
    end
    else begin
        if (x == 12'd1649) begin
            x <= 12'd0;

            if (y == 12'd749) begin
               y <= 12'd0;
            end
            else begin
                y <= y + 1'b1;
            end

        end
        else begin
            x <= x + 1'b1;
        end
    end
end

// 行同步
always @(*) begin
    if (x >= 12'd1390 && x <= 12'd1429) begin
       hsync = 1'b1; 
    end
    else begin
        hsync = 1'b0;
    end
end

// 场同步
always @(*) begin
    if(y >= 12'd725 && y <= 12'd729)
        vsync = 1'b1;
    else
        vsync = 1'b0;
end

assign de = (x < 12'd1280) && (y < 12'd720);
endmodule
