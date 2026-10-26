# Golden reference LeNet-5

## Cặp I/O

Cả ba cặp dùng cùng một ảnh MNIST số 7 (test index 0).

| Khối | Input | Output | Số mẫu |
|---|---|---|---:|
| 1 | `block1_I.hex` — UINT8 `[25,784]` | `block1_O.hex` — INT8 `[6,28,28]` | 1 |
| 2 | `block2_I.hex` — INT8 `[150,100]` | `block2_O.hex` — INT8 `[16,10,10]` | 1 |
| 3 | `block3_I.hex` — INT8 `[400,1]` | `block3_O.hex` — INT32 `[10,1]` | 1 |

## Cách chạy

Đặt `golden_reference.py`, `model_params.npz` và 6 file hex trong cùng một thư mục. Mở terminal tại thư mục đó, rồi chạy:

```powershell
python -m pip install numpy
python golden_reference.py
```

Chương trình đọc ba file input, tính output mới trong thư mục `results_<timestamp>` và so sánh với các file output chuẩn gửi kèm.
