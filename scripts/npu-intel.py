"""Run a deterministic convolution on the NPU, with no model download."""
import sys

import numpy as np
import openvino as ov
from openvino import opset13 as ops


def main():
    core = ov.Core()
    if not any(device.startswith("NPU") for device in core.available_devices):
        print("SKIP: no Intel NPU is available to OpenVINO", file=sys.stderr)
        return 77
    data = ops.parameter([1, 3, 16, 16], np.float32, name="input")
    weights = ops.constant(np.full((4, 3, 3, 3), 0.125, dtype=np.float32))
    conv = ops.convolution(data, weights, [1, 1], [0, 0], [0, 0], [1, 1])
    model = ov.Model([ops.relu(conv)], [data], "aurora-npu-check")
    sample = np.linspace(-1, 1, 768, dtype=np.float32).reshape(1, 3, 16, 16)
    npu = core.compile_model(model, "NPU")
    cpu = core.compile_model(model, "CPU")
    actual = npu([sample])[0]
    expected = cpu([sample])[0]
    np.testing.assert_allclose(actual, expected, rtol=0.02, atol=0.02)
    devices = npu.get_property("EXECUTION_DEVICES")
    if not any(str(device).startswith("NPU") for device in devices):
        raise RuntimeError(f"Unexpected execution devices: {devices}")
    print(f"PASS: Intel NPU convolution matches CPU reference; devices={devices}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
