# LeNet-5 — Nhận diện chữ số viết tay MNIST

Huấn luyện, lượng tử hóa INT8 và bàn giao dữ liệu cho hệ thống nhận diện chữ số trên Tang Nano 4K. Mô hình sử dụng **biến thể LeNet-5**, với C3 kết nối đầy đủ, ReLU, max pooling và output Linear.

## 1. Mô hình và xử lý dữ liệu

```text
Ảnh grayscale 28×28 → Pad 0 thành 32×32
→ Conv1 (1→6, 5×5) → ReLU → MaxPool 2×2
→ Conv2 (6→16, 5×5) → ReLU → MaxPool 2×2
→ Flatten 400 → FC1 (400→120) → ReLU
→ FC2 (120→84) → ReLU → FC3 (84→10) → Argmax
```

Mạng có **61.706 tham số học**. Source triển khai FC1 bằng C5 `Conv2d(16,120,5)` trên tensor `16×5×5`; phép tính tương đương với cách biểu diễn trong sơ đồ khi giữ đúng thứ tự dữ liệu và weights/bias.

- Input: UINT8 `0…255`, nét sáng trên nền tối; thêm viền 0 rộng 2 pixel mỗi cạnh. Training dùng `pixel/255`.
- Integer inference: weights INT8 `−127…127`; bias, accumulator và logits INT32. Sau mỗi lớp ẩn: **ReLU → requant → clip `0…127`**, lưu INT8; phép nhân requant dùng INT64.
- Output: 10 logits cho các số `0…9`; lấy chỉ số lớn nhất, giữ chỉ số đầu khi hòa. Không dùng softmax.

## 2. Training và kết quả

MNIST được chia thành **54.000 train / 6.000 validation / 10.000 test**. Training dùng Adam, learning rate `0.001`, batch size `64`, `20` epoch, seed `42`; chọn checkpoint theo validation loss thấp nhất (**epoch 8**). Sau training thực hiện PTQ, calibration bằng 4.096 ảnh train và chọn cấu hình bằng validation.

| Đánh giá trên 10.000 ảnh test | Kết quả |
|---|---:|
| Model float | **98,99%** — 9.899 ảnh đúng |
| Model INT8 / C integer | **98,94%** — 9.894 ảnh đúng |
| So sánh C/Python integer ở cả 15 tensor | **0 mismatch** |

Các kết quả trên được kiểm chứng trên CPU. **Chưa triển khai và đánh giá LeNet-5 trên FPGA/camera.**

## 3. Các file cần dùng

| Vị trí | Nội dung |
|---|---|
| [`lenet5/`](lenet5/) | Source mô hình, training, evaluation, PTQ và integer inference |
| [`Diagrams/`](Diagrams/) | Sơ đồ thuật toán |
| [Kết quả float](outputs/lenet5/float_20260930_142800_567918/) | `lenet5_best.pt`, cấu hình, split, history, metrics và đồ thị |
| [Kết quả INT8](outputs/lenet5/int8_20260930_145802_710572/) | `lenet5_int8.npz`, metadata, scales, bounds và metrics |
| [C integer](outputs/lenet5/c_20260930_153721_165471/) | Source/header C, parameters và full-test report |
| [Bộ nhớ FPGA](outputs/lenet5/mem_20260930_173742_222887/) | 23 file `.mem`, manifest và full-test report |

Bộ `.mem` gồm **18 file tham số/hệ số theo lớp**, **1 image tổng hợp** và **4 file reference**. Files theo lớp và `model_image.mem` là hai cách đóng gói cùng tham số; reference dùng để đối chiếu khi triển khai phần cứng. Chi tiết tại [INTEGER_SPEC.md](lenet5/INTEGER_SPEC.md) và [MEM_SPEC.md](lenet5/MEM_SPEC.md).

## 4. Kiểm tra nhanh

Chạy PowerShell tại thư mục `LeNet-5`:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe check_handoff.py
```

Script kiểm tra hash các file bàn giao và logits/class của **17 mẫu reference**; không thay thế đánh giá full test 10.000 ảnh. Phiên bản môi trường gốc được ghi trong `ENVIRONMENT.json`.

Dataset và `.venv` không kèm trong repo. Muốn train/evaluate, cần MNIST tại `data/MNIST/raw/`; source đọc dữ liệu local với `download=False`. Luôn lưu kết quả chạy mới vào thư mục mới.

Đây là bản bàn giao gọn. Một số đường dẫn và thông tin kiểm chứng trong artifacts/đặc tả vẫn thuộc project gốc; chạy lại toàn bộ audit/export lịch sử cần bản lưu trữ đầy đủ và điều chỉnh đường dẫn.
