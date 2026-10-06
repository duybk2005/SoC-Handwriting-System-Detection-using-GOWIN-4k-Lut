# Xuất và kiểm chứng .mem — LeNet-5 biến thể B

Đã hoàn thành **xuất tham số, đọc lại và kiểm chứng suy luận trên CPU**. Giữ nguyên mạng B, C5 convolution, weights/scales/bias/multiplier/shift của model đã chốt; không train/quantize lại. Chưa viết RTL, chạy synthesis/P&R, nạp FPGA/HyperRAM hoặc tích hợp camera.

Output đạt: `outputs/lenet5/mem_20260930_173742_222887/`.
Nguồn chuẩn: `outputs/lenet5/int8_20260930_145802_710572/lenet5_int8.npz`.
C golden reference: `outputs/lenet5/c_20260930_153721_165471/lenet5.dll`.
Exporter mới: [export_mem.py](export_mem.py). Các source Python/C và kết quả trước đây được giữ nguyên.

## 1. Bộ files và định dạng

**23 files .mem** gồm 18 files parameters/constants theo lớp, một byte image tổng hợp và bốn files reference nhỏ. Mỗi dòng đúng một từ hex chữ thường, không header/comment/address marker; newline LF. Số âm biểu diễn bù hai. File INT8 có2 ký tự/dòng, INT32 có8 ký tự/dòng. Scalar M/S cũng là một dòng INT32.

| Lớp | Weight INT8 / words | Bias INT32 / words | Multiplier INT32 | Shift INT32 |
|---|---:|---:|---:|---:|
| C1 | `c1_weight.mem`:150 | `c1_bias.mem`:6 | `c1_multiplier.mem`:1669522 | `c1_shift.mem`:30 |
| C3 | `c3_weight.mem`:2400 | `c3_bias.mem`:16 | `c3_multiplier.mem`:2616330 | `c3_shift.mem`:30 |
| C5 | `c5_weight.mem`:48000 | `c5_bias.mem`:120 | `c5_multiplier.mem`:1981865 | `c5_shift.mem`:30 |
| F6 | `f6_weight.mem`:10080 | `f6_bias.mem`:84 | `f6_multiplier.mem`:3025526 | `f6_shift.mem`:30 |
| Output | `output_weight.mem`:840 | `output_bias.mem`:10 | không requant | không requant |

Tổng **61.470 weights +236 biases +8 constants =61.714 giá trị**. Weights+bias có61.706 tham số học và62.414byte dữ liệu; constants thêm32byte. Các files riêng là logical tensors; không được suy rằng tất cả sẽ nằm vừa BSRAM nội Tang Nano4K.

Conv weights OIHW, kernel không đảo; index word `((out*in_channels+in)*Kh+ky)*Kw+kx`. Linear `[out,in]`, index `out*in_features+in`. Bias index=output channel/neuron. Tất cả row-major theo C. Trong file INT32, một dòng như `ffffffff` là **một word -1**, không phải bốn dòng hoặc byte order bus. Ví dụ INT8: -127→`81`, -1→`ff`,127→`7f`.

## 2. Byte image HyperRAM

`model_image.mem` chứa **62.528 dòng UINT8**, mỗi dòng2 ký tự; line index0-based chính là byte offset trong image. File ASCII chiếm187.584byte, không phải dung lượng parameters trong RAM. Word32 được tách thành **little-endian bytes**, ví dụ word0x12345678 thành bốn dòng `78`, `56`, `34`, `12`; signed word sử dụng bit pattern bù hai trước khi tách bytes.

| Region | Byte offset | Data bytes | End exclusive |
|---|---:|---:|---:|
| C1 weights |0|150|150|
| C1 biases |152|24|176|
| C3 weights |176|2400|2576|
| C3 biases |2576|64|2640|
| C5 weights |2640|48000|50640|
| C5 biases |50640|480|51120|
| F6 weights |51120|10080|61200|
| F6 biases |61200|336|61536|
| Output weights |61536|840|62376|
| Output biases |62376|40|62416|
| Coefficients C1(M,S),C3(M,S),C5(M,S),F6(M,S) |62416|32|62448|

Vùng 150..151 align padding2byte; 62448..62463 round-up16byte; 62464..62527 guard64byte. Tất cả padding/guard bằng0, tổng82byte. Payload=62.446byte gồm weights/bias/constants. Mapping khớp khảo sát trước đây, không đổi layout của tensors. Bias/constants compact ở RAM nội sau này phải do loader chuyển, không tự đồng nhất với external byte map.

**Đây là image dữ liệu, chưa phải bitstream/firmware hoặc giao thức nạp HyperRAM.** Controller/loader FPGA sau này phải đọc đúng bytes/addresses, chuyển sang đơn vị địa chỉ IP nếu cần và xác minh model_ready. Việc file tồn tại không có nghĩa HyperRAM đã được nạp hoặc FPGA đã nhận diện được. Không lưu float scales trong image: datapath integer dùng M/S; scales đầy đủ được giữ trong manifest để truy xuất nguồn gốc/diễn giải logits.

## 3. Files reference

17 mẫu theo đúng thứ tự `reference_manifest.json` giai đoạn3:10 mẫu nhãn0..9,5 ảnh có prediction float/integer khác nhau,2 synthetic toàn0/toàn255. Synthetic **không có nhãn MNIST**. Indices/labels/source của từng mẫu được chép vào manifest mới.

| File | Kiểu / shape | Word count | Thứ tự |
|---|---|---:|---|
| `reference_raw_input.mem` | UINT8[17,28,28] |13328|sample,y,x|
| `reference_padded_input.mem` | UINT8[17,1,32,32] |17408|sample,C,H,W|
| `reference_logits.mem` | INT32[17,10] |170|sample,class|
| `reference_class.mem` | UINT8[17] |17|sample|

Raw input dùng pad0 hai pixel mỗi cạnh; padded input có viền0 kể cả synthetic raw255. Không chia255 bằng float khi chạy integer. Full accumulator/activation/pool/flatten golden traces của17 mẫu vẫn ở `reference.npz` giai đoạn3 và `reference_c.npz` giai đoạn4; không tạo testbench RTL hoặc header chứa dataset10.000 ảnh.

## 4. Kiểm chứng thực sự đã chạy

1. Gate model: NPZ/checkpoint/source/dataset/split/calibration/selection/scales/bounds và reports giai đoạn3 khớp. Gate C: full-test15tensors/10.000 ảnh thành công, source/build/DLL/report hashes khớp. Không xuất từ model khác hoặc lấy constants MLP.
2. Codec kiểm tra bằng các literal hex độc lập cho INT8 âm/dương, INT32 min/max/-1/0 và UINT8 0/127/128/255. Decoder yêu cầu đúng word count, đúng số hex digits từng dòng; khôi phục signed bù hai và shape row-major.
3. Đọc lại18 files: toàn bộ61.714 giá trị khớp NPZ. Đọc lại byte image, tách theo offsets/little-endian: cùng61.714 giá trị khớp files riêng và NPZ; padding/guard đúng0. Tái tính bounds vẫn đúngINT32/INT64. Float metadata/scales được giữ nguyên từ NPZ đã xác minh, không suy ra từ hex.
4. Mở DLL C đã kiểm chứng, đọc parameters/constants qua accessor: khớp model dựng lại từ image. Không viết C mới hoặc rebuild/thay DLL cũ.
5. Model dựng lại từ **files riêng** và từ **byte image** đều khớp mọi tensor của17 reference đã lưu. Reference .mem cũng được đọc lại từng từ; không dùng17 mẫu để kết luận full-test accuracy.
6. Chạy model integer dựng lại từ **model_image.mem** trên toàn bộ official MNIST test, batch32: so cả15tensors với C DLL cho **mọi ảnh**, đồng thời so logits/class với giai đoạn3. **0 mismatch, max absolute difference0**. Files riêng chứa arrays giống hệt model image, và đã được kiểm tra reference; full-test inference chạy từ model image, không tuyên bố full test hai lần cho hai bản.
7. Đọc lại tất cả23 files và kiểm tra hash khi kết thúc. **569 files source/artifacts được bảo vệ không đổi**, gồm MLP và toàn bộ output LeNet/khảo sát trước lần xuất này. README/status chỉ được bổ sung và lưu prefix/snapshot.

Kết quả full test mới: **9.894/10.000 đúng=98,94%**; confusion matrix giống integer đã chốt. Float baseline98,99% không train/evaluate lại trong bước này. Đây là kiểm chứng CPU của dữ liệu `.mem`, **không phải accuracy hoặc latency FPGA/camera**.

## 5. Reports và tái tạo

| Artifact | Nội dung |
|---|---|
| `manifest.json` | Format,shapes/dtype/words/layout/hash của23files, address map, constants/scales/bounds, source/model/DLL provenance và links reports |
| `parameter_roundtrip.json` | 61.714 values, image offsets/payload/padding và0 mismatch |
| `c_parameter_comparison.json` | Parameters đọc từ chính DLL khớp model mem |
| `reference_comparison.json` | Files riêng/image khớp cả15tensors của17reference |
| `full_test_report.json` | Count/elements/mismatch/maxdiff từngtensor, full10.000ảnh, accuracy và C/model/report hashes |
| `test_predictions.npz` | Official indices/labels, logits/classes đọc từ mem-model và confusion matrix |
| `input_verification.json` | Gates/hash của model và C trước xuất |
| `source/`, `run.log` | Exporter/dependency snapshots và log |
| `protected_before.json`, `preservation.json` | SHA-256 của569files trước/sau không đổi |
| `documentation_snapshot/`, `documentation_manifest.json`, `final_audit.json` | Tài liệu bàn giao, prefix README/status và hash audit cuối |

PowerShell tại project root:

```powershell
.\.venv\Scripts\python.exe -m lenet5.export_mem
```

Tự tạo `outputs/lenet5/mem_<timestamp>/`. Hoặc `--out outputs/lenet5/mem_custom_01`; output phải mới/rỗng dưới `outputs/lenet5/`, từ chối thư mục không rỗng. Không chạy lại vào thư mục bàn giao; nếu gate lỗi, giữ `failure.json` và không coi các .mem của lần đó là verified.

**Điểm dừng:** đã có model float/integer, C golden reference, khảo sát FPGA và `.mem` round-trip/full-test. Có thể dùng bằng chứng này trong báo cáo về xuất tham số và đề xuất triển khai FPGA; chưa khẳng định đã chạy FPGA/OV2640. Không thực hiện RTL/synthesis/board/camera/Word ở bước này.
