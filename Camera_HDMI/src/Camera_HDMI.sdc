create_clock -name clk -period 37.037 [get_ports {clk}]
create_clock -name cam_pclk -period 41.667 [get_ports {cam_pclk}]
create_clock -name pix_clk -period 13.468 [get_pins {u_clkdiv/CLKOUT}]
