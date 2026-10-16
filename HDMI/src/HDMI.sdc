# Tang Nano 20K onboard 27 MHz oscillator.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

# 1080p30 pixel clock: 74.25 MHz.
create_clock -name pix_clk -period 13.468 -waveform {0 6.734} [get_pins {u_clkdiv/CLKOUT}]
