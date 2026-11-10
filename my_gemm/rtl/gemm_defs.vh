// gemm_defs.vh - hang so dung chung cho khoi GEMM
// Nguon: detail.md Bang 1/Bang 2 (16 lane, n = 4),
//        manifest.json hyperram_image.regions (ban do dia chi HyperRAM, GD3).
`ifndef GEMM_DEFS_VH
`define GEMM_DEFS_VH

`define GEMM_LANES      16      // so lane MAC (slide 14)
`define GEMM_NSTEP      4       // n = 4 nhip / bank element (detail.md GT2)

// Ban do dia chi byte trong HyperRAM (manifest.json, GD3)
`define HR_C1_W         24'd0
`define HR_C1_B         24'd152
`define HR_C3_W         24'd176
`define HR_C3_B         24'd2576
`define HR_C5_W         24'd2640
`define HR_C5_B         24'd50640
`define HR_F6_W         24'd51120
`define HR_F6_B         24'd61200
`define HR_OUT_W        24'd61536
`define HR_OUT_B        24'd62376
// Vung activation (P1, P2, V, H3, H4) do controller ngoai dat vao (GD3)
`define HR_ACT_BASE     24'h010000

// Out_buffer: 2 x 1176 word (Phase 1, 2 x 1/4 cua 4704 word) (GD14)
`define OB_DEPTH        2352
`define OB_AW           12

`endif
