module led_blink(
    input clk,      // Clock hệ thống
    input rst_n,    // Nút nhấn reset (tích cực mức thấp)
    output reg led  // Chân xuất ra LED
);

reg [26:0] counter; 

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        counter <= 0;
        led <= 1'b1; // Tắt LED
    end else begin
        counter <= counter + 1'b1;
        if (counter == 27'd81349_9999) begin // Đếm 3 giây (27MHz)
            counter <= 0;
            led <= ~led; // Đảo trạng thái LED
        end
    end
end
endmodule