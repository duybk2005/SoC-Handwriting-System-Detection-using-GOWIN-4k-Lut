"""Selected LeNet-5 variant B; this is not the original 1998 architecture."""
from collections import OrderedDict

import torch
from torch import nn

MODEL_ID = "lenet5_variant_b_v1"
PARAMETERS = 61706
EXPECTED_SHAPES = {
    "c1": [6, 28, 28], "s2": [6, 14, 14],
    "c3": [16, 10, 10], "s4": [16, 5, 5],
    "c5": [120, 1, 1], "flatten": [120],
    "f6": [84], "output": [10],
}


class LeNet5B(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.Sequential(OrderedDict([
            ("c1", nn.Conv2d(1, 6, 5)), ("relu1", nn.ReLU()),
            ("s2", nn.MaxPool2d(2, 2)),
            ("c3", nn.Conv2d(6, 16, 5)), ("relu3", nn.ReLU()),
            ("s4", nn.MaxPool2d(2, 2)),
            ("c5", nn.Conv2d(16, 120, 5)), ("relu5", nn.ReLU()),
            ("flatten", nn.Flatten(1)),
            ("f6", nn.Linear(120, 84)), ("relu6", nn.ReLU()),
            ("output", nn.Linear(84, 10)),
        ]))

    def forward(self, x):
        return self.layers(x)

    def parameter_description(self):
        return {name: {"shape": list(p.shape), "elements": p.numel(),
                       "dtype": str(p.dtype), "bytes": p.numel() * p.element_size()}
                for name, p in self.named_parameters()}
