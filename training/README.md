\# MNIST MLP Training and Integer Inference



Mô hình MLP nhận dạng chữ số MNIST, hướng tới triển khai trên

Tang Nano 4K.



\## Architecture



28x28 grayscale image

→ flatten 784

→ FC1 784x16

→ ReLU/requantization

→ FC2 16x10

→ argmax



!\[MLP architecture](docs/MLP.png)



\## Results



\- Architecture: 784 → 16 → 10

\- Parameters: 12,730

\- Float test accuracy: 95.13%

\- Integer/C test accuracy: 95.04%

\- Float/integer agreement: 99.59%

\- C/Python mismatches on 10,000 test images: 0



\## Integer data types



\- Input: UINT8

\- Weights: INT8

\- Biases: INT32

\- Accumulators: INT32

\- Hidden activation: INT8, range 0..127

\- Requantization intermediate: INT64



\## C inference



The exported C implementation is in `outputs/c\_run1`.



```c

int mlp\_infer(

&#x20;   const uint8\_t image\[784],

&#x20;   int32\_t acc1\[16],

&#x20;   int8\_t hidden\[16],

&#x20;   int32\_t logits\[10]

);

