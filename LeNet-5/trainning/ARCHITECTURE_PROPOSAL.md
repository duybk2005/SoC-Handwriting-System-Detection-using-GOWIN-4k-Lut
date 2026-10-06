# LeNet-5 cho MNIST trên Tang Nano 4K — đặc tả đề xuất (giai đoạn 1)

**Trạng thái kiến trúc:** Người thực hiện đã chọn **B — biến thể LeNet-5** cho giai đoạn 2. Giữ đối chiếu A/B bên dưới làm tài liệu khảo sát. Bảng tham số được tính từ kiến trúc; kết quả thực nghiệm được ghi riêng trong `README.md` và thư mục chạy. Việc chọn B không phải xác nhận giảng viên đã chấp thuận biến thể hoặc mạng đã triển khai trên FPGA.

## Hiện trạng project và phần có thể dùng lại

- `data/MNIST/raw/` đã có các file IDX train/test. `.venv/` đã có PyTorch và torchvision theo `PROJECT_STATUS.md`; giai đoạn sau cần kiểm tra lại môi trường khi chạy.
- `train_mlp.py` cho thấy cách dùng `torchvision.datasets.MNIST`, `ToTensor`, chia 54.000/6.000 bằng seed 42, ghi checkpoint theo validation và đánh giá 10.000 ảnh test. Có thể dùng **quy trình** này; input LeNet-5 cần giữ dạng `[N,1,H,W]` thay vì flatten.
- `quantize_mlp.py` có các ý tưởng hữu ích: lượng tử weight đối xứng, kiểm tra cận accumulator, nhân/dịch requant và kiểm tra serialization. Scale, miền activation, hệ số requant và cận của MLP **không áp dụng** cho LeNet-5.
- `verify_full.py` là mẫu cho kiểm chứng Python/C trên toàn bộ test qua buffer `ctypes`, không tạo header chứa ảnh. `export_mem.py` là mẫu cho quy ước hex và round-trip; exporter hiện tại gắn chặt vào kiến trúc MLP.
- `demo_image.py` minh họa xử lý ảnh ngoài MNIST (nét sáng/nền đen, căn giữa 28×28). Quy trình camera OV2640 sau này cần được đối chiếu riêng với preprocessing của LeNet-5; một ảnh demo không đại diện cho accuracy camera.
- `rtl/mac_lane.v` và `rtl/mac16_core.v` hiện là thiết kế MLP 16 lane, nhân UINT8×INT8. Có thể tham khảo phép MAC/pipeline và testbench, nhưng chưa thể coi là convolution engine: LeNet-5 cần duyệt cửa sổ, kênh và feature map, cấp phát bộ nhớ cùng băng thông tương ứng. `PROJECT_STATUS.md` đã ghi kết quả mô phỏng và timing cho core MLP; chưa có hệ thống chạy board.
- Các kết quả MLP trong `outputs/run1`, `outputs/int8_run1`, `outputs/c_run1` là baseline riêng. Mọi lần chạy LeNet-5 về sau tạo thư mục mới dưới `outputs/lenet5/`.

## LeNet-5 theo bài báo năm 1998

Ảnh vào 1×32×32. Convolution 5×5, stride 1, không padding; subsampling 2×2, stride 2. Bài báo mô tả sáu tầng C1, S2, C3, S4, C5, F6 rồi tầng output RBF. Ký hiệu `C×H×W` là số kênh, chiều cao và chiều rộng. Các lớp tới F6 dùng hàm sigmoid dạng scaled tanh. S2/S4 lấy tổng hoặc trung bình vùng 2×2, nhân hệ số học được theo từng feature map, cộng bias học được rồi qua activation; hệ số của tổng và trung bình có thể quy đổi qua nhau nên số tham số không đổi.

| Tầng | Đầu ra | Tham số có thể học | Cách tính |
| --- | ---: | ---: | --- |
| Input | 1×32×32 | 0 | Ảnh đã chuẩn bị |
| C1 | 6×28×28 | 156 | `6×(1×5×5+1)` |
| S2 | 6×14×14 | 12 | `6×(scale+bias)` |
| C3 | 16×10×10 | 1.516 | 60 kết nối map-kênh ×25 + 16 bias |
| S4 | 16×5×5 | 32 | `16×(scale+bias)` |
| C5 | 120×1×1 | 48.120 | `120×(16×5×5+1)` |
| F6 | 84 | 10.164 | `84×(120+1)` |
| Output | 10 khoảng cách | 0 tham số học trong cấu hình ban đầu | 10 tâm RBF ×84 giá trị chọn trước; chọn **khoảng cách nhỏ nhất** |
| **Tổng** | | **60.000** | Không tính 840 giá trị tâm RBF cố định là tham số học |

C3 chỉ có **60 kết nối giữa 6 map S2 và 16 map C3**, theo Bảng I của bài báo: 6 map đầu nhận 3 kênh, 6 map sau nhận 4 kênh liên tiếp, 3 map tiếp nhận 4 kênh không liên tiếp, map cuối nhận cả 6. Một `Conv2d(6,16,5)` thông thường kết nối đầy đủ và có 2.416 tham số, nên không tái hiện C3 gốc. C5 tạo 120 map 1×1; với kích thước input này nó tương đương một lớp FC 400→120 về phép toán, nhưng bài báo gọi là convolution.

Đầu ra gốc là 10 **khoảng cách Euclid bình phương** từ vector F6 đến các tâm RBF chọn trước. Giá trị nhỏ hơn phù hợp lớp hơn. Nếu thay bằng `Linear(84,10)` và chọn `argmax`, đó là thay kiến trúc và quy tắc quyết định. Tâm RBF ban đầu là hằng số chọn bằng tay; nếu cho học trong thí nghiệm khác thì phải ghi riêng cách huấn luyện và số tham số tương ứng.

Bài báo dùng input 32×32, có thể mở rộng MNIST 28×28 bằng pixel nền. Chuẩn hóa đầu vào của thí nghiệm gốc có quy ước riêng để đưa mức nền/nét về miền quanh 0; không được đồng nhất nó với `ToTensor()` 0..1 trong project MLP.

## Hai lựa chọn cho project

| | A — tái hiện LeNet-5 gốc | B — biến thể LeNet-5 đề xuất cho FPGA |
| --- | --- | --- |
| Kiến trúc | C3 kết nối thưa; S2/S4 có scale và bias học được; scaled tanh; RBF | C3 kết nối đủ; max pool cố định; ReLU; Linear 10 |
| Ưu điểm | Sát bài báo, thuận lợi khi giải thích lịch sử mô hình | Dễ dựng bằng PyTorch; activation và pooling dễ đặc tả bằng số nguyên; output là logits để chọn `argmax` |
| Việc khó khi lượng tử hóa | Scaled tanh cần xấp xỉ/LUT; subsampling có tham số; RBF cần tính khoảng cách; C3 cần bảng kết nối | Vẫn phải chọn scale từng lớp, kiểm tra accumulator và lưu feature maps; C3 đầy đủ làm tăng tính toán/tham số so với C3 gốc |
| Cách gọi trong báo cáo | LeNet-5 gốc, nếu tái hiện đầy đủ cả preprocessing và output | **Biến thể LeNet-5 cho FPGA**; liệt kê rõ các thay đổi |

**Người thực hiện đã chọn B** cho nhánh thực nghiệm đầu tiên. Cơ sở của đề xuất là các phép activation, pooling và output thuận tiện cho đặc tả số nguyên; đây chưa phải bằng chứng mô hình vừa tài nguyên Tang Nano 4K hoặc được giảng viên chấp thuận. Nếu thầy yêu cầu bản nguyên gốc, cần khảo sát lại A; không đổi tên một biến thể thành “nguyên bản”.

### Đặc tả cụ thể của lựa chọn B đã chốt

- Input MNIST: ảnh UINT8 28×28, nét sáng/nền tối như dữ liệu IDX. Pad **2 pixel giá trị 0 ở mỗi cạnh** thành 1×32×32. Với mô hình float, đổi pixel sang `float32/255` sau hoặc trước padding; không chuẩn hóa mean/std khác. Giữ nhất quán với đường dữ liệu integer sau này: raw UINT8 0..255, pad bằng 0. Ảnh camera phải được tiền xử lý về đúng quy ước nét/nền, vị trí và kích thước này trước khi suy luận.
- Layout tensor trong PyTorch: NCHW. Convolution kernel 5×5, stride 1, padding 0; max pool 2×2, stride 2. ReLU sau C1, C3, C5 và F6. Output Linear 10 trả logits; `argmax` chọn chỉ số đầu tiên khi bằng nhau; không cần softmax khi suy luận.
- Loss huấn luyện dự kiến: cross entropy trên logits. Đây là kế hoạch, chưa chọn hyperparameter hoặc train.

| Tầng B | Đầu ra | Tham số học | Cách tính |
| --- | ---: | ---: | --- |
| Input sau pad | 1×32×32 | 0 | 28×28 → 32×32 |
| C1 Conv+ReLU | 6×28×28 | 156 | `6×(1×25+1)` |
| S2 MaxPool | 6×14×14 | 0 | 2×2, stride 2 |
| C3 Conv+ReLU | 16×10×10 | 2.416 | `16×(6×25+1)` |
| S4 MaxPool | 16×5×5 | 0 | 2×2, stride 2 |
| C5 Conv+ReLU | 120×1×1 | 48.120 | `120×(16×25+1)` |
| F6 Linear+ReLU | 84 | 10.164 | `84×(120+1)` |
| Output Linear | 10 logits | 850 | `10×(84+1)` |
| **Tổng** | | **61.706** | 61.706 tham số học |

Đối chiếu A→B: C3 `1.516→2.416` (+900); bỏ 44 tham số S2/S4; thêm 850 tham số output Linear; tổng `60.000→61.706` (+1.706). Các shape và số tham số ở bảng B là số tính toán từ công thức. Độ chính xác, dung lượng sau lượng tử hóa và mức dùng LUT/DSP/RAM chưa được đo.

## Điểm dừng và nguồn

Người thực hiện đã chốt **B**, giữ nguyên đặc tả B làm mốc cho train và các giai đoạn kiểm chứng sau. Giai đoạn 2 dừng sau huấn luyện/đánh giá float; quantization, C và FPGA là các giai đoạn tiếp theo.

- LeCun, Bottou, Bengio, Haffner, *Gradient-Based Learning Applied to Document Recognition*, Proceedings of the IEEE 86(11), 1998, mục II-B và Bảng I: <https://leon.bottou.org/publications/pdf/ieee-1998.pdf>. Trang thư mục của đồng tác giả: <https://bottou.org/papers/lecun-98h>.
- Trang bài báo của IEEE: <https://proceedingsoftheieee.ieee.org/gradient-based-learning-applied-to-document-recognition/>.
- Source và tình trạng project: `AGENTS.md`, `PROJECT_STATUS.md`, `train_mlp.py`, `quantize_mlp.py`, `verify_full.py`, `export_mem.py`, `demo_image.py`, `rtl/README.md`.
