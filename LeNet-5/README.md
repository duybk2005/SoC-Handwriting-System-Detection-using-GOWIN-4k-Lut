# LeNet-5 — bản bàn giao gọn

Biến thể LeNet-5 B, 61.706 tham số: C3 kết nối đầy đủ, ReLU, max pooling, Linear output. Float MNIST test 98,99%; PTQ INT8/C 98,94%. C/Python khớp cả 15 tensor trên đủ 10.000 ảnh. Đã xuất và kiểm chứng đọc lại 23 file `.mem`; chưa có RTL LeNet-5 hoặc kiểm chứng FPGA/camera.

## Các phần cần dùng

- `lenet5/model.py`: kiến trúc mạng.
- `lenet5/train.py`: training; `evaluate.py`: đánh giá checkpoint; `quantize.py`: PTQ.
- `lenet5/data.py`, `common.py`, `plots.py`, `__init__.py`: dependencies của các chương trình trên. Giữ cùng nhau để import và chạy được.
- `lenet5/integer.py`: suy luận integer bằng NumPy từ model đã chốt.
- `lenet5/INTEGER_SPEC.md`, `MEM_SPEC.md`: đặc tả số học và định dạng bộ nhớ lịch sử.
- `diagrams/LeNet-5.drawio`: sơ đồ thuật toán. Flatten 400 → FC1(400,120) trong sơ đồ tương đương C5 Conv(16,120,5) trong source khi giữ đúng thứ tự CHW và weights/bias.

## Kết quả quan trọng

Các đường dẫn sau nằm trong `outputs/lenet5/`:

| Thư mục | Nội dung đã giữ |
|---|---|
| `float_20260930_142800_567918/` | Best checkpoint epoch 8, config, split, history, metrics, đồ thị loss/accuracy và test metrics |
| `int8_20260930_145802_710572/` | Model INT8, metadata, scales, bounds, lựa chọn PTQ, metrics |
| `c_20260930_153721_165471/` | 4 file source/header C gồm parameters, full-test report và metrics |
| `mem_20260930_173742_222887/` | 23 `.mem`, manifest và full-test report |

18 `.mem` là weights/bias/multiplier/shift từng lớp; `model_image.mem` là cách đóng gói tổng hợp cùng tham số; 4 file reference là dữ liệu kiểm tra. Không cần nạp đồng thời cả hai cách đóng gói tham số. Giữ reference để nhóm so sánh khi triển khai phần cứng.

Đã bỏ checkpoint cuối, source snapshots, candidate PTQ không chọn, run thử, log/audit chi tiết, predictions toàn tập, DLL và khảo sát FPGA. Các tài liệu đặc tả lịch sử có thể nhắc exporter, DLL, helper và báo cáo chỉ có trong bản lưu trữ đầy đủ; những phần đó không kèm trong bản gọn này.

## Cài môi trường và nạp model

Chạy PowerShell tại thư mục `LeNet-5`:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe check_handoff.py
```

Kiểm tra bàn giao xác minh file hashes và logits/class của 17 reference; đây không phải phép đo accuracy trên 10.000 ảnh. `ENVIRONMENT.json` ghi phiên bản máy gốc. Requirements không khóa phiên bản, cần kiểm chứng lại khi đổi môi trường.

Suy luận integer nhận ảnh raw UINT8 `[N,28,28]`, nét sáng/nền tối, chưa pad:

```python
from lenet5.integer import load_model, inference
params = load_model('outputs/lenet5/int8_20260930_145802_710572/lenet5_int8.npz')
# raw là numpy.ndarray UINT8 [N,28,28]
logits, classes, stats, trace = inference(raw, params, intermediates=True)
```

## Training mới

Không đưa dataset hoặc `.venv` lên Git. Tải MNIST một lần vào `data/` nếu cần train/evaluate:

```powershell
.\.venv\Scripts\python.exe -c "from torchvision.datasets import MNIST; MNIST('data', train=True, download=True); MNIST('data', train=False, download=True)"
.\.venv\Scripts\python.exe -m lenet5.train --epochs 20 --batch-size 64 --lr 0.001 --seed 42 --threads 4
```

PTQ cho run float mới: `python -m lenet5.quantize --float-run outputs/lenet5/float_<run_mới>`. Đường dẫn phải là run thực tế; source không cho ghi đè output có sẵn.

Bản gọn dùng để đọc source, nạp model và bàn giao dữ liệu triển khai. Không đủ để replay toàn bộ audit/export lịch sử: artifacts cũ giữ đường dẫn máy gốc và hashes/dependencies của project MLP/RTL, snapshots đã lược bỏ. Không sửa báo cáo cũ để giả lập provenance mới. Giữ bản đầy đủ ở máy khi cần kiểm chứng lại pipeline từ artifacts cũ.
