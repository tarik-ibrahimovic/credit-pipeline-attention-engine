import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

# ---------------- utils ----------------
def signext(v: int, bits: int) -> int:
    """Sign-extend integer v of given bit-width to Python int."""
    mask = (1 << bits) - 1
    v &= mask
    s = 1 << (bits - 1)
    return (v ^ s) - s

def encode_q0_7(x: float) -> int:
    q = int(np.round(x * 128.0))
    return int(np.clip(q, -128, 127)) & 0xFF

def decode_uq3_6(lo8: int, hi1: int) -> float:
    raw = ((hi1 & 1) << 8) | (lo8 & 0xFF)
    return raw / 64.0

def set_bit(val: int, bit: int, one: bool) -> int:
    return (val | (1 << bit)) if one else (val & ~(1 << bit))

# ---------------- exact RTL model of ex(.): mirrors your Verilog ----------------
def ex_logic_model_q(x_s8: int) -> int:
    """
    Bit-identical to the posted RTL ex() module.
    Input:  x_s8 = int8 signed, Q1.6
    Output: 9-bit unsigned UQ3.6 (0..0x1FF)
    """

    # x (Q1.6) as 8-bit signed
    x8 = signext(x_s8, 8)

    # ----- n = round(x/ln2) with the exact RTL sequence and widths -----
    # mul92 = x*92 with 16-bit wrap
    x16 = signext(x8, 16)
    mul92 = signext((x16 << 7) - (x16 << 5) - (x16 << 2), 16)  # 128-32-4

    # nq2_6 = mul92 >>> 6 (still 16-bit signed)
    nq2_6 = signext(mul92 >> 6, 16)

    # round-to-nearest: add +/- 32 depending on sign of nq2_6, then >>> 6
    offs = -32 if (nq2_6 < 0) else 32
    nq2_6_rnd = signext(nq2_6 + offs, 16)
    n_full = signext(nq2_6_rnd >> 6, 16)  # still 16b signed

    # Verilog: wire signed [2:0] n_round = 3'( ... );
    # That is: take ONLY the lower 3 bits, interpret as signed 3-bit
    n3_u = n_full & 0x7
    n_round = n3_u - 8 if (n3_u & 0x4) else n3_u   # signed 3-bit in Python

    # ----- r = {x[7],x} - (n*44)[8:0] (with exact widths and truncation) -----
    # {x[7],x} is a 9-bit signed concat
    x9 = signext(((x8 & 0x80) << 1) | (x8 & 0xFF), 9)

    # n_se (10-bit signed), nL (10-bit), then truncate to 9 LSBs and interpret as signed
    n10  = signext(n_round, 10)
    nL10 = signext((n10 << 5) + (n10 << 3) + (n10 << 2), 10)  # *44
    nL9  = signext(nL10 & 0x1FF, 9)                           # [8:0], signed

    r_q16 = signext(x9 - nL9, 9)  # still Q1.6 but carried in 9 bits

    # ----- polynomial e^r ≈ 1 + r + r^2/2 in Q0.16 with the same widths -----
    # Q1.6 -> Q0.16: left shift by 10, keep 19b signed
    r_q0_16 = signext(r_q16, 9) << 10
    r_q0_16 = signext(r_q0_16, 19)

    # r^2: 19x19 -> 38b, then >>>16 -> 22b, then /2 -> 22b
    r2_q0_32 = signext(r_q0_16, 19) * signext(r_q0_16, 19)
    r2_q0_32 = signext(r2_q0_32, 38)
    r2_q0_16 = signext(r2_q0_32 >> 16, 22)
    r2h_q0_16 = signext(r2_q0_16 >> 1, 22)

    one_q0_16 = signext(65536, 22)         # 1.0 in Q0.16
    r_ext_q0_16 = signext(r_q0_16, 22)
    e_r_q0_16 = signext(one_q0_16 + r_ext_q0_16 + r2h_q0_16, 22)

    # Apply 2^n via shift on 32b signed
    e32 = signext(e_r_q0_16, 32)
    if n_round >= 0:
        e_scaled = signext(e32 << n_round, 32)
    else:
        e_scaled = signext(e32 >> (-n_round), 32)

    # Convert to UQ3.6: if negative clamp to 0; else arithmetic >>>10, saturate to 9b
    if e_scaled < 0:
        return 0
    uq36_pre = e_scaled >> 10
    if uq36_pre > 0x1FF:
        return 0x1FF
    return uq36_pre & 0x1FF

# ---------------- DUT helpers ----------------
async def reset(dut, cycles=5):
    dut.rst_n.value = 0
    dut.uio_in.value = 0
    dut.ui_in.value = 0
    await Timer(1, "ns")
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)

async def feed_term(dut, a_q07: int, b_q07: int):
    """Send one 2-beat term with vld held high across both beats.
       Expects RDY=1 in FIRST (for A) and again in WAIT4SECOND (for B)."""
    # deassert vld, clear data
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, False)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)

    # --- Beat 1 (A) ---
    # Wait until DUT is ready in FIRST
    while ((int(dut.uio_out.value) >> 1) & 1) == 0:
        await RisingEdge(dut.clk)

    # Present A and assert vld
    dut.ui_in.value = a_q07
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, True)
    await RisingEdge(dut.clk)  # A captured; DUT transitions to WAIT4SECOND

    # --- Beat 2 (B) ---
    # Now wait again for RDY=1 in WAIT4SECOND
    while ((int(dut.uio_out.value) >> 1) & 1) == 0:
        await RisingEdge(dut.clk)

    # Present B while keeping vld high
    dut.ui_in.value = b_q07
    await RisingEdge(dut.clk)  # B captured; DUT transitions to READY (does MAC)

    # Deassert vld and clear data
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, False)
    dut.ui_in.value = 0


async def drain_output(dut):
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)
    await RisingEdge(dut.clk)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, False)

async def wait_for_valid(dut, cycles=200):
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if ((int(dut.uio_out.value) >> 2) & 1) == 1:
            return
    assert False, "Timeout waiting for vld_mst_out_w=1"
def sclip(v: int, bits: int) -> int:
    """Wrap to 'bits'-wide signed two's-complement."""
    v &= (1 << bits) - 1
    s = 1 << (bits - 1)
    return (v ^ s) - s

def rtl_reduce_mac_to_q1_6(mac_sum_int: int) -> int:
    """
    Emulate RTL path:
      mac_reg: 17-bit signed accumulator (Q2.14)
      mac_div2 = arithmetic >>>1 -> Q1.15
      mac_reduced = mac_div2[16:9] -> 8-bit signed Q1.6
    Returns int8 value (two's-complement) as Python int in [-128,127].
    """
    mac17    = sclip(mac_sum_int, 17)          # wrap to 17b signed like the reg
    mac_div2 = sclip(mac17 >> 1, 17)           # arithmetic >>>1 (keep 17b)
    x_s8     = np.int8((mac_div2 >> 9) & 0xFF).item()  # slice [16:9] -> int8
    return x_s8

def mac_path_reference(pairs_q):
    prods = []
    for aq, bq in pairs_q:
        a = np.int8(aq).item()
        b = np.int8(bq).item()
        prods.append(int(a) * int(b))

    mac_sum = int(np.int32(np.sum(prods)))     # 4 terms, fits 17b signed
    x_s8 = rtl_reduce_mac_to_q1_6(mac_sum)     # EXACTLY like RTL wiring

    # For logging: convert int8 Q1.6 to integer/floating representations
    x_fixed = signext(x_s8, 8)                 # still Q1.6 integer in [-128,127]
    x_real  = x_fixed / 64.0

    return mac_sum, x_fixed, x_real, x_s8


def read_dut_y(dut):
    lo8 = int(dut.uo_out.value) & 0xFF
    hi1 = (int(dut.uio_out.value) >> 4) & 1
    raw9 = ((hi1 & 1) << 8) | lo8
    return raw9, raw9 / 64.0

# ---------------- minimal test to compare DUT vs model ----------------
@cocotb.test()
async def test_single_dot_exp(dut):
    """Feed one dot (4 terms), compare DUT vs bit-accurate model (not vs float)."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    # same vector that showed 0x03A vs 0x038 before
    pairs_real = [(-0.75, 0.50), (0.25, -0.50), (0.60, 0.40), (-0.30, 0.20)]
    pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]
    for (aq, bq) in pairs_q:
        await feed_term(dut, aq, bq)

    await wait_for_valid(dut)
    dut_raw, y_dut = read_dut_y(dut)
    await drain_output(dut)

    _, x_fixed, x_real, x_s8 = mac_path_reference(pairs_q)
    model_raw = ex_logic_model_q(x_s8)
    y_model = model_raw / 64.0

    dut._log.info(f"x_fixed={x_fixed} (Q1.6)  x_real={x_real:.6f}")
    dut._log.info(f"DUT:   raw=0x{dut_raw:03X}  y={y_dut:.6f}")
    dut._log.info(f"MODEL: raw=0x{model_raw:03X} y={y_model:.6f}")

    assert dut_raw == model_raw, f"DUT raw 0x{dut_raw:03X} != model 0x{model_raw:03X}"
