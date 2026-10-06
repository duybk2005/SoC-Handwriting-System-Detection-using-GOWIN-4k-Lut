# LeNet-5 handoff

- Scope: lenet5_variant_b_v1, MNIST, 61,706 parameters. This is separate from the older MLP project.
- Read README.md and relevant source/specifications before changing files.
- Preserve existing outputs/lenet5 runs; generate results in a new run directory.
- Keep C5 Conv2d(16,120,5) in source. The diagram may show equivalent Flatten(400) -> FC1(400,120).
- Raw input UINT8 28x28, pad 2 zeros on every edge; float pixel/255. Conv OIHW, feature CHW.
- Weights INT8 -127..127; biases/accumulators/logits INT32; hidden INT8 0..127.
- Use per-layer multipliers from INTEGER_SPEC.md, INT64 before requant multiplication, first-index argmax. No softmax.
- Do not apply the old MLP multiplier 435395 to LeNet-5.
- Original reports include original absolute paths and MLP preservation gates; do not silently rewrite historical evidence or claim it can be replayed unchanged here.
- No LeNet-5 RTL/FPGA/camera validation is supplied. Hardware feasibility documents are proposals.
