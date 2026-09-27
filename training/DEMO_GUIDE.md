# Demo nhận dạng ảnh ngoài MNIST trên laptop

Mở PowerShell tại `C:\Users\ADMIN\prj_1`. Không cần train lại hoặc kết nối board. Cần .venv hiện có và GCC tại C:/msys64/ucrt64/bin/gcc.exe.

## Cách 1: đưa ảnh 28x28 vào C

```powershell
.\.venv\Scripts\python.exe .\demo_image.py --image .\demo_assets\seven_28x28.png --ready --label 7
```

`--ready` giữ nguyên 784 pixel grayscale, không resize hoặc tách nền lại. Demo tự nhận dạng, không cần cung cấp nhãn.

Kết quả đã kiểm tra: `C prediction: 7`; C/Python mismatch bằng 0 ở acc1, hidden, logits và class.

## Cách 2: trình bày cả bước tiền xử lý

```powershell
.\.venv\Scripts\python.exe .\demo_image.py
```

Lệnh mặc định dùng ảnh mực xanh trên giấy tải từ Wikimedia. Python tách nền bằng Otsu, đổi thành nét sáng, resize giữ tỷ lệ trong 20x20, căn trọng tâm trong 28x28. C thực hiện toàn bộ MLP với model đã train. Quy trình này dành cho ảnh một chữ số rõ và nền tương đối đều, không phải bộ tách chữ tổng quát.

Mỗi lần chạy tạo thư mục `outputs/external_demo_<thời gian>` mới. Dòng cuối terminal in đường dẫn `demo.html`; mở file này trong trình duyệt để trình bày ảnh và kết quả. Trang lưu kết quả của lần chạy đó; muốn đổi ảnh phải chạy lại lệnh.

## Lời trình bày ngắn

1. Đây là ảnh viết tay bên ngoài MNIST, có nguồn trong demo_assets/SOURCE.md.
2. Ảnh đầu vào mạng có 28x28 pixel UINT8, flatten theo hàng thành 784 byte.
3. Python đọc ảnh và gọi C bằng buffer. MLP chạy bằng C trên CPU laptop.
4. C dùng weight INT8, bias/accumulator INT32; FC1 → ReLU/requant → FC2 → argmax.
5. Kết quả là 7. Python integer được chạy thêm để kiểm chứng cả các tầng trung gian.
6. Đây là demo một ảnh, không phải accuracy ngoài MNIST và chưa phải chạy trên FPGA.

## Thử ảnh riêng

```powershell
.\.venv\Scripts\python.exe .\demo_image.py --image 'C:\duong-dan\anh.png'
```

Nếu ảnh đã là 28x28, nét sáng trên nền đen, thêm `--ready`. Model luôn chọn 0–9, chưa có lớp từ chối ảnh không phải chữ số. Logits là điểm số, không phải xác suất.

Đầu ra gồm original.png, input_28x28.png, input_preview.png, input_uint8.bin (784 byte), mlp_demo.dll, result.json và demo.html. Không sửa ba thư mục baseline.
