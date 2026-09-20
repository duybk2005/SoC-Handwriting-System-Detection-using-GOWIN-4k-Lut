# Trạng thái đã xác minh — 2026-09-12

## Cấu trúc và phạm vi kiểm tra

- Source gốc: train_mlp.py, check_checkpoint.py, quantize_mlp.py, export_c.py. Đã đọc toàn bộ source, JSON, history.csv và C inference/test harness; header dữ liệu được kiểm chứng bằng tái xuất và so sánh.
- data/MNIST/raw: đủ train/test IDX và bản gzip; .venv: Python 3.14.6, PyTorch 2.14.0+cpu, NumPy 2.5.2.
- outputs/run1: checkpoint, metrics.json, history.csv (20 epoch, best epoch 20).
- outputs/int8_run1: model, calibration report, split indices, 100 reference vectors.
- outputs/c_run1: weights.h, inference.c/.h, main.c, test_vectors.h, manifest, test_mlp.exe.
- Không train lại; tái chạy kiểm tra checkpoint, quantization và exporter vào thư mục riêng. Không viết RTL.

## Kết quả thực tế

| Kiểm tra | Kết quả |
| --- | --- |
| Kiến trúc / số tham số | 784 -> 16 -> 10 / 12.730 |
| Float checkpoint, 10.000 ảnh | 9.513 đúng = 95,13% |
| Python integer, 10.000 ảnh | 9.504 đúng = 95,04% |
| C biên dịch lại, 10.000 ảnh | 9.504 đúng = 95,04% |
| Float/integer agreement | 9.959/10.000 = 99,59% |
| Giảm accuracy | 0,09 điểm phần trăm |
| C/Python mismatch | acc1=0, hidden=0, logits=0, class=0; 0 ảnh sai khác |
| C test cũ, biên dịch lại | 0 mismatch; accuracy tập con 98/100 |
| Calibration tái chạy | percentile 99,5; multiplier 435395, shift 30 |
| Cận trị tuyệt đối accumulator | FC1: 3.802.125; FC2: 91.279; vừa INT32 |
| Baseline | SHA-256 trước/sau không đổi |

Full test dùng verify_full.py: torchvision đọc IDX cục bộ (download=False), NumPy tạo reference; ctypes truyền từng buffer UINT8 sang DLL biên dịch từ chính outputs/c_run1/inference.c. Không đưa dataset vào header. GCC 16.1.0, c99/O2/Wall/Wextra/Werror. Báo cáo có hash model, source, dataset và baseline. Đây là kiểm chứng C trên CPU, chưa là kiểm chứng phần cứng.

## File bổ sung và kết quả

- verify_full.py: chạy lại test C 100 ảnh, full test C/Python và float, lưu report/predictions; từ chối ghi đè thư mục không rỗng.
- export_mem.py: yêu cầu full-test report thành công và hash baseline khớp trước khi xuất; kiểm tra round-trip từng từ hex và inference từ model đọc lại.
- outputs/full_test_run1/: verification_report.json, predictions.npz, test_100.txt, test_100.exe, mlp.dll.
- outputs/int8_audit_run1/ và outputs/c_audit_run1/: kết quả tái chạy pipeline cũ, tách khỏi baseline.
- audit_comparison.json trong outputs/full_test_run1 xác nhận: cả 6 file C/header/manifest tái xuất giống từng byte; mọi mảng trong 3 NPZ và toàn bộ quantization_report.json tái chạy giống baseline; hash baseline vẫn không đổi sau xuất .mem.
- outputs/mem_run1/: fc1_weight.mem (12.544 từ INT8), fc1_bias.mem (16 từ INT32), fc2_weight.mem (160 từ INT8), fc2_bias.mem (10 từ INT32).
- Cùng thư mục mem: reference_input.mem, reference_acc1.mem, reference_hidden.mem, reference_logits.mem, reference_class.mem và manifest.json.
- Reference gồm 10 ảnh (mỗi nhãn 0..9 một ảnh trong 100 vector gốc), ảnh toàn 0 và ảnh toàn 255. Manifest ghi index/nhãn; ảnh tổng hợp không có nhãn MNIST. Reference dùng thứ tự sample-major, rồi row-major; signed dùng bù hai. Mỗi dòng là một từ hex, không phải chuỗi byte cần đổi endian.
- AGENTS.md: quy ước ổn định; PROJECT_STATUS.md: tài liệu này.

## Điểm cần lưu ý

Không phát hiện sai khác thuật toán hoặc số liệu baseline so với mô tả. Python integer dùng INT64 cho dot product làm reference có kiểm tra, rồi trả accumulator INT32; C thực sự tích lũy INT32, phù hợp thiết kế.

Môi trường sandbox ban đầu không khởi chạy được .venv (Access denied); chạy có quyền đã thành công. GCC cần C:/msys64/ucrt64/bin trong PATH để tìm DLL; verify_full.py tự thêm cho tiến trình. Không sửa source baseline để xử lý môi trường.

train_mlp.py mặc định trỏ outputs/run1 và có thể ghi đè nếu chạy lại; luôn chỉ định --out mới. Hai exporter/quantizer cũ có kiểm tra thư mục không rỗng.

Repo tham khảo https://github.com/mqqz/mnist-fpga-nn hiện mô tả Tang Nano 9K / 784 -> 32 -> 10; chỉ tham khảo pipeline và định dạng .mem, không dùng hệ số hay cấu hình board của họ cho Tang Nano 4K.

## Tái chạy (PowerShell tại thư mục project)

```powershell
.venv/Scripts/python.exe check_checkpoint.py
.venv/Scripts/python.exe quantize_mlp.py --out outputs/int8_audit_run2
.venv/Scripts/python.exe export_c.py --out outputs/c_audit_run2
.venv/Scripts/python.exe verify_full.py --out outputs/full_test_run2
.venv/Scripts/python.exe export_mem.py --verification outputs/full_test_run2/verification_report.json --out outputs/mem_run2
```

## Bước tiếp theo

Gate C 10.000 ảnh và xuất .mem đã hoàn thành. Tiếp theo cần chốt đặc tả phần cứng Tang Nano 4K: ngân sách ROM/RAM, độ rộng/địa chỉ và độ trễ đọc bộ nhớ, MAC tuần tự hay song song, giao thức start/busy/done. Dữ liệu tham số thuần chiếm 12.808 byte; đây chưa phải mức sử dụng block RAM sau ánh xạ.

Sau khi chốt đặc tả, nhiệm vụ RTL riêng sẽ triển khai matvec -> ReLU/requant -> FC2 -> argmax, rồi testbench dùng bộ reference hiện có để đối chiếu mọi tầng trước synthesis. Chưa xác minh tài nguyên, timing hay hoạt động trên FPGA.
