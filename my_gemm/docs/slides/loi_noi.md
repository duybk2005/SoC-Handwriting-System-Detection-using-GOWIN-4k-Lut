# Lời nói khi thuyết trình (đi kèm slides.pdf)

Mỗi slide khoảng 1 phút, cả bài khoảng 20 phút. Phần in nghiêng là gợi ý thao tác khi trình bày.

---

## Slide 1 – Khối GEMM: bộ máy nhân-cộng của LeNet-5

"Phần của mình là khối GEMM, bộ phận làm toàn bộ việc tính toán nặng của mạng LeNet-5 trên FPGA. Hôm nay mình trình bày 3 ý: mình code cái gì, nó chạy thế nào, và làm sao biết nó tính đúng."

*Chỉ vào hình 16 ô: "Mỗi ô là một làn nhân-cộng, 16 làn chạy cùng lúc. Lát nữa sẽ giải thích."*

## Slide 2 – LeNet-5 làm gì, và khối GEMM nằm ở đâu?

"LeNet-5 nhận một ảnh chữ viết tay 28×28 và đoán đó là số mấy. Đây là ảnh thật trong bộ dữ liệu của nhóm, số 7.

Ảnh đi qua 5 bước: C1, C3, C5, F6, Output. Điểm quan trọng: cả 5 bước đều là cùng một kiểu phép toán, nhân rồi cộng dồn. Vì vậy thay vì làm 5 khối khác nhau, mình làm **một khối GEMM và dùng lại 5 lần**. Mỗi lần dùng gọi là một phase.

Những bước nhỏ ở giữa như ReLU, pool, làm tròn là việc của khối khác, không nằm trong phần của mình."

## Slide 3 – Phép toán cốt lõi

"Lấy ví dụ một neuron có 3 input: 10, 20, 5. Mỗi input có một trọng số: 2, −1, 3. Ta nhân từng cặp: 20, −20, 15, cộng thêm bias 4, ra 19.

Mạng thật có hàng trăm neuron, mỗi neuron hàng trăm input. Làm phép này cho tất cả cùng lúc thì viết gọn thành **kết quả = W × P + B**, tức là nhân ma trận. Khối làm việc này tên là GEMM, viết tắt của General Matrix Multiplication."

## Slide 4 – Lớp Conv cũng biến được thành nhân ma trận

"Lớp Conv thì sao? Conv là trượt một cửa sổ 5×5 trên ảnh.

*Chỉ khung cam:* Ở mỗi vị trí, mình lấy 25 con số trong cửa sổ, đây là giá trị pixel thật, rồi duỗi thẳng thành một cột 25 số. Ảnh 28×28 có 784 vị trí, nên ra 784 cột. Ghép lại thành ma trận P1 kích thước 25 × 784.

Bộ lọc 5×5 cũng duỗi thành một hàng 25 số. Như vậy Conv cũng thành W × P + B, đúng dạng GEMM. Việc duỗi ảnh, gọi là im2col, mình giả định do khối khác làm trước."

## Slide 5 – Khối GEMM được dùng 5 lần

"Đây là 5 lần dùng. Mỗi lần có 3 con số kích thước:
- M: có bao nhiêu bộ lọc hay neuron.
- K: mỗi kết quả phải cộng dồn bao nhiêu tích.
- N: có bao nhiêu vị trí. Với lớp FC thì N = 1.

Thanh ngang là khối lượng việc. Phase 2 nặng nhất, 240 nghìn phép nhân-cộng. Phase 5 nhẹ nhất, chỉ 840. Phase 1 và 2 là Conv, phase 3 đến 5 là FC (lớp kết nối đầy đủ)."

## Slide 6 – 16 làn nhân-cộng chạy cùng lúc

"Ý tưởng phần cứng như sau. Có một 'số chung' được phát cho cả 16 làn. Mỗi làn cầm một 'số riêng' của mình. Mỗi nhịp clock, cả 16 làn cùng nhân số chung với số riêng, rồi cộng vào ô nhớ Σ của làn đó.

Lặp K nhịp thì 16 ô nhớ chứa 16 kết quả hoàn chỉnh, gọi là một block. Xong block này thì xóa ô nhớ, làm block tiếp. Cách này đúng như slide 14 của nhóm trưởng, gọi là Output-Stationary."

## Slide 7 – Hai cách chia việc cho 16 làn

"Cùng phần cứng đó nhưng có hai cách chia việc.

- **Conv:** 16 làn là 16 pixel liền nhau trên cùng một hàng kết quả. Số chung là một trọng số của bộ lọc, 16 số riêng là 16 pixel. Bias của 16 làn giống nhau, vì cùng một bộ lọc.
- **FC:** 16 làn là 16 neuron. Số chung là một input, 16 số riêng là trọng số của 16 neuron. Mỗi neuron có bias riêng.

*Đọc ví dụ ở dưới:* Phase 1 có 294 block, mỗi block 25 nhịp. Phase 3 có 8 block, mỗi block 400 nhịp."

## Slide 8 – Dữ liệu ở đâu ra?

"Vấn đề tiếp theo là dữ liệu. Trọng số khoảng 62 KB, không vừa trong chip, nên nằm ở bộ nhớ ngoài HyperRAM. Ống nối tới HyperRAM chỉ rộng 8 bit, tức mỗi clock lấy được 1 byte. Trong khi đó GEMM cần 16 byte mỗi nhịp.

Nên phải có các **khay chứa** đặt sát GEMM, gồm khay bias, khay số chung và khay số riêng, cùng một **người chở hàng** là DMA, lo nạp khay trước."

## Slide 9 – Sơ đồ khối mình đã code

"Đây là sơ đồ Figure 1 của nhóm trưởng. Mình code đúng theo nó, mỗi ô là một file Verilog. Đi theo số:
1. Controller nhận phase và start.
2. Nạp bias và số chung vào khay.
3. DMA chở số riêng vào khay ping-pong.
4. GEMM array nhân-cộng. Mỗi lần dùng hết một khay thì báo tick cho controller.
5. Hết K nhịp, controller ra lệnh save để cất kết quả vào Out_buffer.
6. Xong hết thì báo done.

Tên tín hiệu trên sơ đồ như clear, tick, save, load_select đều trùng tên trong Figure 1."

## Slide 10 – Ping-pong

"Khay số riêng có hai cái, A và B, thay phiên nhau. GEMM dùng khay A thì DMA nạp khay B, và ngược lại. Dùng hết khay thì có tín hiệu tick, nghĩa là 'xong khay này, đổi khay'.

Chỗ này có một điểm quan trọng. Spec giả sử DMA nạp kịp một khay 64 byte trong lúc GEMM chạy 4 nhịp. Nhưng ống 8 bit cần ít nhất 64 clock để chở 64 byte, nên không kịp. Mình thêm **cờ valid**: khay chưa đầy thì GEMM tự đứng chờ. Như hình, GEMM chạy một chút rồi chờ. Nhờ vậy kết quả luôn đúng, dù bộ nhớ nhanh hay chậm."

## Slide 11 – Một lượt chạy trông như thế nào

"Đây là hình dạng tín hiệu khi chạy Phase 5, giống hình trong waveform ModelSim:
- start lên, rồi nạp số chung và bias.
- clear một nhịp để xóa ô nhớ và đặt bias vào.
- mac_en nhấp nháy, mỗi xung là một nhịp nhân-cộng, có khoảng chờ DMA ở giữa. Cứ 4 nhịp có một tick.
- Hết 84 nhịp thì save 10 lần, mỗi clock ghi một kết quả.
- Cuối cùng done lên.

Đếm trong ModelSim ra đúng 84 nhịp, 21 tick, 10 lần save. Các phase khác chỉ là lặp vòng này nhiều block hơn."

## Slide 12 – Trong folder my_gemm có gì

"Folder my_gemm gồm:
- **rtl:** 10 file mạch, mỗi file ứng với một ô trong sơ đồ vừa rồi.
- **tb:** máy kiểm tra.
- **sim:** script chạy mô phỏng, log và waveform.
- **syn:** script thử đưa lên chip Gowin.
- **docs:** tài liệu.

Code đầy đủ sẽ để trên GitHub, nên ở đây mình chỉ giải thích ý tưởng, không chiếu code."

## Slide 13 – Làm sao biết mạch tính đúng?

"Cách kiểm tra như sau. Mình cho dữ liệu thử vào HyperRAM giả lập, để khối GEMM tự đọc và tự tính. Song song, testbench tự tính đáp án bằng vòng lặp W × P + B bình thường. Sau đó so từng con số: khớp hết thì PASS, lệch một số là FAIL.

Có một mẹo: trọng số dùng để tính đáp án lấy từ file .mem riêng, không lấy từ chỗ mạch đọc. Nếu mạch đọc nhầm địa chỉ thì kết quả mạch sẽ khác đáp án, và lỗi bị bắt ngay.

Ngoài ra còn kiểm số lần clear, tick, save có đúng công thức không, và done có lên đúng một lần không."

## Slide 14 – Kết quả

"Kết quả:
- 30 trên 30 lượt test PASS.
- Gần 48 nghìn con số được so, không sai số nào.
- Chạy ở 3 tốc độ bộ nhớ: nhanh, chậm, rất chậm, kết quả vẫn giống nhau.

Cả 5 phase đều đúng. Riêng Phase 1 còn chạy với ảnh MNIST thật là số 7. Mình còn thử bấm start bậy lúc mạch đang bận, mạch bỏ qua đúng như thiết kế."

## Slide 15 – Thử phá mạch

"Test PASS hết thì có thể nghi: liệu bài test có dễ dãi quá, cái gì cũng cho qua không? Nên mình cố ý cài 4 lỗi vào code rồi chạy lại.

Ô đỏ là test báo lỗi. Lỗi nào cũng bị bắt, và chỉ đúng những test liên quan mới đỏ:
- **Lỗi 1**, coi pixel là số có dấu: chỉ Phase 1 đỏ, vì chỉ ảnh gốc mới có pixel lớn hơn 127.
- **Lỗi 2**, đọc lệch địa chỉ trọng số: các phase FC đỏ. T1c vẫn xanh vì input toàn số 0, nhân với trọng số nào cũng ra 0.
- **Lỗi 3**, quên cất kết quả cuối mỗi block: đỏ hết.
- **Lỗi 4**, lấy nhầm khay: chỉ Phase 2 đỏ.

Vậy bài test đáng tin."

## Slide 16 – Đưa lên chip Gowin

"Mình chạy thử phần mềm tổng hợp của Gowin cho chip GW1NSR-4C. Lần đầu mạch cần 5 408 ô logic, chip chỉ có 4 608, tức là tràn.

Nguyên nhân: phần mềm gộp 'nhân và cộng' vào một loại khối đặc biệt mà chip chỉ có 8 cái. 8 làn còn lại phải dựng bằng logic thường nên tốn chỗ.

Cách sửa: nhân xong thì cất tạm, nhịp sau mới cộng. Khi đó 16 phép nhân dùng được 16 bộ nhân có sẵn trong chip. Còn 3 355 ô, khoảng 73%, vừa chip. Bộ nhớ trong chip (BSRAM) dùng tới 90%, cần để ý khi ghép với phần khác."

## Slide 17 – Tốc độ

"Chạy cả 5 phase mất khoảng 13 ms cho một ảnh ở 50 MHz. Nhưng chỉ 4,3% thời gian là thật sự nhân-cộng, phần còn lại là chờ dữ liệu từ HyperRAM. Tức nút cổ chai là ống 8 bit, không phải phần tính.

Phase 2 lâu nhất, vì cách quét hiện tại phải đọc lại dữ liệu ảnh 16 lần, mỗi bộ lọc một lần. Đây là chỗ có thể tối ưu sau."

## Slide 18 – Những chỗ cần nhóm trưởng chốt

"Spec có vài chỗ chưa rõ. Mình đã chọn tạm một cách hợp lý và ghi lại, gồm 4 chỗ chính:
1. Khay số riêng to bao nhiêu: detail.md và Figure 1 ghi khác nhau.
2. DMA không nạp kịp như giả thuyết: có cần ống rộng hơn không.
3. Bias giữ 16 số hay cả vector.
4. Ai duỗi ảnh và ảnh nằm ở đâu.

Mỗi chỗ mình có ghi nếu đổi thì sửa file nào, nên sửa không tốn nhiều công. Đủ 18 giả định nằm trong file báo cáo."

## Slide 19 – Tóm lại

"Tóm lại:
- Đã code xong khối GEMM 10 module đúng sơ đồ Figure 1.
- Đã kiểm gần 48 nghìn con số đều đúng, và test bắt được cả 4 lỗi cài vào.
- Mạch vừa chip, khoảng 13 ms một ảnh.

Bước tiếp theo: chốt các giả định với nhóm trưởng, ghép bộ điều khiển HyperRAM thật, chạy cả mạng rồi so với đáp án phần mềm, cuối cùng nạp lên board. Cảm ơn mọi người."

---

## Câu hỏi có thể bị hỏi

**Sao biết đáp án của testbench là đúng?**
Đáp án tính bằng vòng lặp W × P + B rất đơn giản, đúng công thức trong slide nhóm trưởng. Trọng số đọc thẳng từ file .mem do phần training xuất ra.

**Tại sao 16 làn mà không phải 32?**
Theo thiết kế của nhóm trưởng (slide 14: 16-lane MAC array). Chip có đủ bộ nhân 9×9 có sẵn cho 16 làn (Gowin báo dùng 16 khối MULT9X9).

**Sao có số "9 bit" trong khi dữ liệu là 8 bit?**
Trọng số là số có dấu (−128..127), còn pixel là số không dấu (0..255). Mở rộng cả hai thành 9 bit có dấu thì nhân chung một kiểu được mà không sai dấu.

**Kết quả có bị tràn số không?**
Ô nhớ kết quả 32 bit. Theo file manifest của phần training, mọi lớp đều nằm trong giới hạn 32 bit.

**Đã chạy trên board chưa?**
Chưa. Mới mô phỏng và chạy thử tổng hợp. Bước tiếp theo là ghép HyperRAM thật rồi nạp board.

**13 ms có chậm không?**
Với nhận dạng chữ số từ camera thì đủ dùng (khoảng 75 ảnh mỗi giây). Muốn nhanh hơn thì cần ống dẫn rộng hơn hoặc giảm số lần đọc lại ở Phase 2.
