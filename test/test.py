import cocotb
from cocotb.triggers import Timer
import numpy as np
import matplotlib.pyplot as plt

OUT_FRAC = 6   # 6 for UQ3.6, 5 for UQ3.5
OUT_MASK = 0x1FF  # 9-bit for UQ3.6; use 0xFF for 8-bit

@cocotb.test()
async def test_ex(dut):
    x = np.arange(-2.0, 2.0 + 1e-4, 1e-4)
    approx_array = np.empty_like(x, dtype=float)
    real_array   = np.exp(x)

    for idx, val in enumerate(x):
        q16 = int(np.clip(np.round(val * 64.0), -128, 127))
        dut.mac_result.value = q16 & 0xFF       # drive 8-bit bus correctly

        await Timer(1, "ns")                    # allow settle

        y_bits = int(dut.ex_result.value) & OUT_MASK
        approx_array[idx] = y_bits / (2.0 ** OUT_FRAC)

    np.savetxt("approx_array.txt", approx_array)
    error = np.abs(approx_array - real_array)
    plt.plot(x, error, label="|approx - exp(x)|")
    plt.legend(); plt.xlabel("x"); plt.ylabel("error"); plt.grid(True)
    plt.savefig("ex_error.png", dpi=150)
