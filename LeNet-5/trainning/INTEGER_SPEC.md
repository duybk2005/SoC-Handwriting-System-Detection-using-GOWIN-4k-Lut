# Đặc tả số nguyên LeNet-5 biến thể B — giai đoạn 3

Đây là đặc tả đã được kiểm chứng bằng Python integer trên MNIST, dựa trên mạng B đã train ở giai đoạn 2. Chưa triển khai C/RTL, xuất `.mem`, synthesis hoặc chạy Tang Nano 4K/OV2640. Kiến trúc và preprocessing giữ nguyên; không train lại, không QAT.

Lần chạy được bàn giao: `outputs/lenet5/int8_20260930_145802_710572/`. Checkpoint float: `outputs/lenet5/float_20260930_142800_567918/lenet5_best.pt`, epoch 8, 61.706 tham số, C5 là convolution. SHA-256 checkpoint: `effe4fb5b09cf55273899649e296040c7213964073fbdaad464e4b6a824730f3`.

## 1. Quy ước tensor và đường suy luận

Input API là raw `UINT8 [N,28,28]`, miền 0..255, nét sáng/nền tối. Pad 2 pixel **0** mỗi cạnh thành `[N,1,32,32]`. Input scale `1/255`, zero-point 0; không chia 255 bằng float trong đường suy luận integer, không resize hoặc normalize mean/std.

| Bước / tên reference | Shape mỗi mẫu (bỏ N) | Kiểu lưu |
| --- | --- | --- |
| `raw_input` | 28×28 | UINT8 |
| `input` sau pad | 1×32×32 | UINT8 |
| `c1_acc` | 6×28×28 | INT32 |
| `c1_activation` sau ReLU/requant/clip | 6×28×28 | INT8 0..127 |
| `s2` max pool | 6×14×14 | INT8 0..127 |
| `c3_acc` | 16×10×10 | INT32 |
| `c3_activation` | 16×10×10 | INT8 0..127 |
| `s4` max pool | 16×5×5 | INT8 0..127 |
| `c5_acc` | 120×1×1 | INT32 |
| `c5_activation` | 120×1×1 | INT8 0..127 |
| `flatten` | 120 | INT8 0..127 |
| `f6_acc` | 84 | INT32 |
| `f6_activation` | 84 | INT8 0..127 |
| `output_acc`, `logits` (cùng giá trị) | 10 | INT32 |
| `predictions` | scalar | NumPy INT64, giá trị 0..9 |

Feature maps NCHW; convolution weights OIHW: `[out_channel,in_channel,kernel_y,kernel_x]`. Conv dùng **cross-correlation**, stride 1, không convolution padding, không lật kernel. Các lớp C1/C3/C5 đều kernel 5×5, C3 kết nối đầy đủ. Linear weights `[out,in]`. Flatten C trước, rồi y và x row-major. Batch chỉ là tiện ích phần mềm; dữ liệu mỗi mẫu độc lập.

| Lớp | Weight shape | Weight INT8 / byte | Bias INT32 / byte |
| --- | --- | ---: | ---: |
| C1 | 6×1×5×5 | 150 | 6 / 24 |
| C3 | 16×6×5×5 | 2.400 | 16 / 64 |
| C5 | 120×16×5×5 | 48.000 | 120 / 480 |
| F6 | 84×120 | 10.080 | 84 / 336 |
| Output | 10×84 | 840 | 10 / 40 |
| Tổng | | 61.470 | 236 / 944 |

Weights+bias thuần chiếm **62.414 byte**, chưa gồm scale/multiplier, feature buffers, metadata, padding/alignment hoặc overhead ánh xạ FPGA. File NPZ nén chiếm 57.043 byte; dung lượng file nén không phải dung lượng ROM phần cứng.

## 2. PTQ và calibration

Weights đối xứng, **một scale mỗi tensor**, INT8 -127..127, zero-point 0. Bias INT32. Hidden activation sau ReLU INT8 0..127, zero-point 0. Không dùng scale hoặc multiplier MLP.

Calibration lấy **4.096 index đầu tiên theo thứ tự train indices đã lưu** trong split giai đoạn 2. Train có 54.000 ảnh, validation 6.000 ảnh; calibration không giao validation. `calibration_indices.npz` lưu cả indices và labels. Không dùng test để xác định scale hoặc chọn percentile.

Chạy checkpoint float trên calibration, đo tensor **sau ReLU, trước pooling** ở C1/C3, sau ReLU ở C5/F6. Percentile tính trên mọi phần tử, gồm cả số 0, bằng NumPy `method="linear"`. Đây là calibration float; không phải calibration tuần tự dùng activation integer. Khi inference, activation đã requant của lớp trước được truyền sang lớp sau.

Bốn ứng viên công bố trước khi chạy trong `plan.json`: 99,0; 99,5; 99,9; 100. Mỗi ứng viên dùng cùng percentile cho cả bốn lớp hidden. Chọn theo số ảnh validation đúng, nếu hòa chọn agreement float/integer cao hơn, nếu vẫn hòa chọn percentile lớn hơn.

| Percentile | Đúng / 6.000 validation | Accuracy | Agreement float/integer |
| --- | ---: | ---: | ---: |
| **99,0 — chọn** | **5.925** | **98,7500%** | 5.984 |
| 99,5 | 5.923 | 98,7167% | 5.989 |
| 99,9 | 5.920 | 98,6667% | 5.996 |
| 100 | 5.919 | 98,6500% | 5.995 |

Float validation: 5.917/6.000. Chọn 99,0 vì accuracy validation cao nhất, dù agreement không cao nhất. Chênh lệch nhỏ trên một split; không khẳng định percentile này tối ưu cho mọi dataset. `selection.json` được lưu và lấy SHA-256 **trước** khi đánh giá integer test, kiểm tra hash không đổi khi kết thúc. Test không dùng để đổi scale, không đánh giá test từng ứng viên rồi chọn phương án tốt nhất.

## 3. Lượng tử hóa tham số

Quy ước giá trị thực x ≈ scale × q, mọi zero-point bằng 0. Làm tròn offline bằng float64:

```text
round_away(x) = sign(x) * floor(abs(x) + 0.5)
round_away(-1.5, -0.5, +0.5, +1.5) = (-2, -1, +1, +2)

weight_scale = max(abs(weight_float)) / 127
q_weight = clip(round_away(weight_float / weight_scale), -127, 127)

accumulator_scale = bias_scale = input_scale * weight_scale
q_bias = round_away(bias_float / bias_scale)

output_scale = calibration_percentile_threshold / 127
```

Weight tensor toàn 0 dùng scale 1; activation threshold 0 dùng output scale 1/127. Kiểm tra scale hữu hạn/dương và bias nằm trong INT32 trước khi cast. `selection.json` lưu sai số dequant weight/bias lớn nhất, tỷ lệ requant và sai số tỷ lệ. Scale lớp kế tiếp bằng output scale lớp trước; pooling giữ nguyên scale.

## 4. MAC, requant và pooling

```text
acc = q_bias + sum(q_input * q_weight)
positive = max(acc, 0)
ratio = accumulator_scale / output_scale
```

Với mỗi ratio, thử shift từ 30 giảm đến 0, chọn shift lớn nhất có:

```text
multiplier = floor(ratio * 2^shift + 0.5)
1 <= multiplier <= 2^31 - 1
represented_ratio = multiplier / 2^shift
```

Nếu không biểu diễn được thì báo lỗi. Sai số tuyệt đối tỷ lệ không quá `0.5 / 2^shift` theo phép làm tròn (có sai số số thực rất nhỏ lúc tạo hệ số); giá trị cụ thể nằm trong `selection.json`. Với các scale đã chọn, cả bốn shift bằng 30.

Đường requant thực tế chỉ dùng số nguyên:

```text
offset = 2^(shift-1) nếu shift > 0, ngược lại là 0
wide = (INT64(positive) * multiplier + offset) >> shift
q_output = clip(wide, 0, 127), lưu INT8
```

Phải ép sang INT64 **trước phép nhân**. Rounding của giá trị không âm là nearest, nửa đơn vị làm tròn lên. Thứ tự: MAC+bias → ReLU → requant → saturation → max pool nếu có. Max pool cửa sổ 2×2 stride 2, không tham số học, không requant thêm. Lưu INT8 không cho phép nhận -128..-1 làm activation.

Python reference nhân/cộng MAC bằng INT64, kiểm tra rồi trả INT32. Đặc tả cho C/RTL sau này là accumulator INT32 với cận đã chứng minh; bit-exact cần cùng weights/bias, rounding, multiplier, shift, layout và saturation.

Output cuối **không** ReLU/requant/softmax. Mười logits INT32 cùng scale `0.00026609613793414236`; trực tiếp argmax. Khi hòa giữ chỉ số đầu tiên: vòng lặp cập nhật class chỉ khi logit mới **lớn hơn** giá trị tốt nhất, không dùng `>=`. Không argmax trực tiếp logits khác scale khi đổi sang per-channel ở nhiệm vụ tương lai.

## 5. Scale và hệ số đã chọn

Các scale dưới đây rút gọn để đọc; `scales.csv`, `selection.json` và các scalar float64 trong NPZ lưu đầy đủ. Khi viết C dùng multiplier/shift đã lưu, không tính lại từ scale rút gọn.

| Lớp | Input scale | Weight scale | Bias/acc scale | Output scale | Multiplier | Shift |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| C1 | 0,003921568627 | 0,006119268147 | 0,000023997130 | 0,015433596532 | **1669522** | **30** |
| C3 | 0,015433596532 | 0,004045916824 | 0,000062443048 | 0,025626628023 | **2616330** | **30** |
| C5 | 0,025626628023 | 0,004726448397 | 0,000121122935 | 0,065622424479 | **1981865** | **30** |
| F6 | 0,065622424479 | 0,003671403710 | 0,000240926413 | 0,085503407426 | **3025526** | **30** |
| Output | 0,085503407426 | 0,003112111505 | 0,000266096138 | acc scale | không requant | — |

## 6. Chứng minh độ rộng

Từng output channel/neuron dùng cận:

```text
bound[o] = input_max * sum(abs(q_weight[o])) + abs(q_bias[o])
input_max = 255 tại C1; 127 tại C3/C5/F6/Output
requant_bound = max(bound) * multiplier + offset
```

Tính abs/sum bằng INT64, product cận requant bằng Python integer. Cận tam giác bao phủ mọi partial sum dù thứ tự cộng thay đổi hoặc cộng bias trước/sau. Không dựa vào việc test không tràn để suy an toàn cho mọi input hợp lệ.

| Lớp | Cận abs accumulator lớn nhất | abs bias lớn nhất | Cận nhân requant+cộng offset |
| --- | ---: | ---: | ---: |
| C1 | 255.067 | 7.462 | 426.376.838.886 |
| C3 | 530.816 | 3.348 | 1.389.326.696.192 |
| C5 | 1.054.752 | 1.341 | 2.090.912.943.392 |
| F6 | 359.359 | 798 | 1.087.786.868.746 |
| Output | 373.269 | 622 | không requant |

Tất cả accumulator/bias nằm trong INT32; tất cả requant intermediates nằm trong INT64. `bounds.json` lưu toàn bộ cận theo channel, không chỉ cực đại. Runtime vẫn kiểm tra accumulator trước cast và product requant trước nhân.

## 7. Kiểm chứng và kết quả thực nghiệm

`arithmetic_checks.json`: PASS rounding ±0,5/±1,5, ReLU/clip, shift=0, phép nhân INT64 lớn, multiplier error, cross-correlation đa kênh với weights âm so với vòng lặp đơn giản, max pool so với vòng lặp, flatten row-major và argmax khi hòa. `network_smoke.json`: forward toàn mạng cho một ảnh calibration và raw toàn 0/toàn 255; synthetic không có nhãn MNIST.

Full official test sau khi chốt quantization, batch integer 32:

| Chỉ tiêu | Kết quả |
| --- | ---: |
| Float đúng / tổng | 9.899 / 10.000 = 98,99% |
| Integer đúng / tổng | **9.894 / 10.000 = 98,94%** |
| Giảm accuracy | **0,05 điểm phần trăm** |
| Float/integer agreement | **9.974 / 10.000 = 99,74%** |
| Số ảnh khác prediction | 26 |
| Reload model — logits khác | 0 / 100.000 giá trị |
| Reload model — class khác | 0 / 10.000 ảnh |

Trong 26 ảnh khác prediction: 13 ảnh float đúng/integer sai, 8 ảnh float sai/integer đúng và 5 ảnh cả hai sai nhưng đoán lớp khác nhau. Vì vậy số ảnh đúng giảm ròng 5, không phải chỉ có 5 ảnh đổi class. `artifact_audit.json` xác nhận các số đếm từ predictions đã lưu, consistency logits/argmax/confusion matrix, model/selection/source hashes và bảo toàn baseline.

Weights/bias/scale/multiplier đọc lại giống từng giá trị; statistics saturation cũng giống. Không yêu cầu float/integer logits bit-exact. Gate bit-exact hiện tại là model integer trước/sau lưu; giai đoạn 4 sẽ cần thêm gate C/Python.

| Lớp | Mẫu số phần tử trên full test | Âm được ReLU đưa về 0 | Vượt 127 sau requant, bị saturation |
| --- | ---: | ---: | ---: |
| C1 | 47.040.000 | 26.803.847 (56,9810%) | 468.695 (0,9964%) |
| C3 | 16.000.000 | 12.531.055 (78,3191%) | 112.792 (0,7050%) |
| C5 | 1.200.000 | 792.802 (66,0668%) | 5.620 (0,4683%) |
| F6 | 840.000 | 445.041 (52,9811%) | 3.143 (0,3742%) |

Mẫu số là mọi phần tử output affine tương ứng, **trước pooling**, gồm cả phần tử âm/0. Saturation chỉ đếm `wide > 127` sau rounding; `wide == 127` không bị thay đổi nên không tính. Số 0 output còn gồm các giá trị dương rất nhỏ làm tròn về 0; không gọi số 0 sau ReLU là lỗi clipping. Thống kê đầy đủ trong `saturation.json`.

Độ chính xác giảm ít trên MNIST này, chưa đánh giá tài nguyên/timing FPGA hoặc accuracy camera. Cận số học chứng minh đủ độ rộng accumulator; chưa chứng minh toàn bộ bộ nhớ/phần cứng của mạng vừa Tang Nano 4K. Không tự chuyển sang per-channel/QAT hoặc tuning bằng test.

## 8. Bàn giao cho giai đoạn 4

- `lenet5/integer.py`: reference integer, `load_model`, `inference(..., intermediates=True)`, `run_dataset` và local checks; inference MAC không dùng PyTorch/float.
- `lenet5/quantize.py`: xác minh float, calibration, chọn bằng validation, full test/reload, xuất artifacts NPZ/JSON/CSV/PNG.
- `lenet5_int8.npz`: mỗi lớp có `{layer}_weight`, `_bias`, `_input_scale`, `_weight_scale`, `_accumulator_scale`; bốn lớp hidden thêm `_output_scale`, `_multiplier`, `_shift`. Scale scalar float64 chỉ phục vụ metadata/offline; multiplier/shift scalar INT32; output không có requant. Common zero-point 0 ghi trong metadata.
- `model_metadata.json`, `selection.json`, `scales.csv`, `bounds.json`: định dạng, scale, provenance và cận đầy đủ. Kiểm tra SHA-256 NPZ trong metadata trước khi viết exporter.
- `reference.npz` và `reference_manifest.json`: **17 mẫu** — một ảnh mỗi nhãn theo test index đầu tiên, 5 ảnh đầu khác prediction, raw toàn 0 và toàn 255. Có raw input, padded input, acc/activation/pool/flatten/logits/class. Hai synthetic có index/label `null`; raw toàn 255 vẫn pad viền bằng 0.
- `test_predictions.npz`: labels/index/predictions float+integer, integer logits INT32 và confusion matrix của đủ 10.000 ảnh. Dùng để gate C/Python toàn tập; reference 17 mẫu không thay thế full-test accuracy.
- `reload_verification.json`, `input_verification.json`, `arithmetic_checks.json`, `preservation.json`: bằng chứng các gate hiện tại; 37 file MLP/RTL và 39 file trong lần chạy float không đổi SHA-256.

Giai đoạn 4 cần triển khai C theo đúng đặc tả và đối chiếu cả accumulator, activation, pooling, logits/class. Hiện chưa tạo C, header dữ liệu, RTL hoặc `.mem` LeNet-5.
