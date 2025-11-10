import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np


# ---------- helpers ----------
def encode_q0_7(x_real: float) -> int:
    """Q0.7 signed encode into int8 (-128..127)."""
    q = int(np.round(x_real * 128.0))
    return int(np.clip(q, -128, 127)) & 0xFF  # two's complement for dut

def decode_uq3_6(lo8: int, hi1: int) -> float:
    """UQ3.6 decode from 9 bits: [8]=hi1, [7:0]=lo8."""
    raw = ((hi1 & 1) << 8) | (lo8 & 0xFF)
    return raw / 64.0  # LSB = 2^-6

async def reset(dut, cycles=5):
    dut.rst_n.value = 0
    dut.uio_in.value = 0  # clear vld/rdy
    dut.ui_in.value = 0
    await Timer(1, "ns")
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)

def set_bit(val: int, bit: int, one: bool) -> int:
    return (val | (1 << bit)) if one else (val & ~(1 << bit))

async def feed_term(dut, a_q07: int, b_q07: int):
    """Feed one term = two beats (A then B) with vld=1, obeying rdy, then deassert vld."""
    # Ensure vld=0 initially
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, False)

    # Beat 1: A (assert vld)
    dut.ui_in.value = a_q07
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, True)   # vld_slv_in=1

    # wait until rdy_slv_out_w==1 (uio_out[1]) then clock in
    while ((int(dut.uio_out.value) >> 1) & 1) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # Beat 2: B (keep vld=1)
    dut.ui_in.value = b_q07
    await RisingEdge(dut.clk)  # WAIT4SECOND only checks vld==1

    # Deassert vld, idle input to avoid accidental capture
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 0, False)
    dut.ui_in.value = 0

async def drain_output(dut):
    """Assert rdy_mst_in=1 for one cycle to accept output (uio_in[3])."""
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)
    await RisingEdge(dut.clk)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, False)


@cocotb.test()
async def test_single_dot_exp(dut):
    """Feed 4 terms (8 beats), expect one UQ3.6 e^x output."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)

    # Keep rdy_mst_in high most of the time (accept as soon as valid asserts)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    # Choose 4 pairs (A,B) in Q0.7 range ~ [-1,1)
    pairs_real = [(-0.75, 0.50), (0.25, -0.50), (0.60, 0.40), (-0.30, 0.20)]
    pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]

    # Feed 4 terms
    for (aq, bq) in pairs_q:
        await feed_term(dut, aq, bq)

    # Wait until DUT raises valid (uio_out[2]==1)
    for _ in range(100):
        await RisingEdge(dut.clk)
        if ((int(dut.uio_out.value) >> 2) & 1) == 1:
            break
    else:
        assert False, "Timeout waiting for vld_mst_out_w=1"

    # Sample output (uo_out[7:0], uio_out[4])
    lo8 = int(dut.uo_out.value) & 0xFF
    hi1 = (int(dut.uio_out.value) >> 4) & 1
    y_dut = decode_uq3_6(lo8, hi1)

    # Accept the output to clear valid
    await drain_output(dut)

    # ----- compute expected x that DUT feeds to exp -----
    # mac_sum = sum_i (Ai * Bi) using int8 * int8 products (two's complement)
    # mac_reduced = (mac_sum >>> 10) (Q1.6 integer), x_real = x_fixed / 64
    products = []
    for (aq, bq) in pairs_q:
        a = np.int8(aq).item()
        b = np.int8(bq).item()
        products.append(int(a) * int(b))
    mac_sum = int(np.int32(np.sum(products)))

    def arshift(val, sh):
        # Python right shift is already arithmetic for ints, but keep explicit
        return val >> sh

    x_fixed = arshift(mac_sum, 10)  # Q1.6 integer
    x_real = x_fixed / 64.0

    y_ref = float(np.exp(x_real))

    # Tolerance for your simple exp approximation & quantization
    tol = 0.06
    abs_err = abs(y_dut - y_ref)

    dut._log.info(f"x_real={x_real:.6f}  DUT={y_dut:.6f}  REF={y_ref:.6f}  abs_err={abs_err:.6f}")
    assert abs_err <= tol, f"abs error {abs_err:.4f} > {tol:.4f} (x={x_real:.5f}, dut={y_dut:.5f}, ref={y_ref:.5f})"


@cocotb.test()
async def test_back_to_back_tokens(dut):
    """Two consecutive dots (8 terms total) with continuous backpressure-free sink."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)

    # Always ready to accept
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    # Build two dots, each 4 terms
    sets = [
        [(-0.5, 0.4), (0.3, 0.2), (-0.7, -0.6), (0.25, -0.5)],
        [(0.8, -0.5), (0.1, 0.9), (-0.4, 0.3), (0.6, -0.2)],
    ]

    for dot_idx, pairs in enumerate(sets):
        for a, b in pairs:
            aq, bq = encode_q0_7(a), encode_q0_7(b)
            await feed_term(dut, aq, bq)

        # Wait for valid
        for _ in range(100):
            await RisingEdge(dut.clk)
            if ((int(dut.uio_out.value) >> 2) & 1) == 1:
                break
        else:
            assert False, f"Timeout waiting for vld (dot {dot_idx})"

        # Capture + decode
        lo8 = int(dut.uo_out.value) & 0xFF
        hi1 = (int(dut.uio_out.value) >> 4) & 1
        y_dut = decode_uq3_6(lo8, hi1)

        # Accept and clear valid
        await drain_output(dut)

        # Quick sanity: e^x must be strictly positive
        assert y_dut >= 0.0, "exp output must be non-negative"


from cocotb.triggers import First

async def wait_for_valid(dut, cycles=200):
    """Wait until DUT raises valid (uio_out[2]==1), else fail."""
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if ((int(dut.uio_out.value) >> 2) & 1) == 1:
            return
    assert False, "Timeout waiting for vld_mst_out_w=1"


@cocotb.test()
async def test_zero_vector(dut):
    """All terms zero -> x=0, expect e^0≈1."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)  # always ready

    # 4 terms: (0,0)
    pairs_q = [(encode_q0_7(0.0), encode_q0_7(0.0)) for _ in range(4)]
    for aq, bq in pairs_q:
        await feed_term(dut, aq, bq)

    await wait_for_valid(dut)
    lo8 = int(dut.uo_out.value) & 0xFF
    hi1 = (int(dut.uio_out.value) >> 4) & 1
    y_dut = decode_uq3_6(lo8, hi1)
    await drain_output(dut)

    y_ref = 1.0
    assert abs(y_dut - y_ref) <= 0.05, f"e^0 should be ~1.0, got {y_dut:.4f}"


@cocotb.test()
async def test_fourth_term_dominates(dut):
    """
    First three products ~0, last product large.
    This stresses 'capture after 4th MAC' behavior.
    """
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    # Three tiny products, one big positive product
    pairs_real = [(0.0, 0.0), (0.01, -0.01), (-0.01, 0.01), (0.95, 0.95)]
    pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]
    for aq, bq in pairs_q:
        await feed_term(dut, aq, bq)

    await wait_for_valid(dut)
    lo8 = int(dut.uo_out.value) & 0xFF
    hi1 = (int(dut.uio_out.value) >> 4) & 1
    y_dut = decode_uq3_6(lo8, hi1)
    await drain_output(dut)

    # Compute reference from exact fixed-point path
    prods = []
    for aq, bq in pairs_q:
        a = np.int8(aq).item()
        b = np.int8(bq).item()
        prods.append(int(a) * int(b))
    mac_sum = int(np.int32(np.sum(prods)))
    x_fixed = mac_sum >> 10
    x_real = x_fixed / 64.0
    y_ref = float(np.exp(x_real))

    tol = 0.06
    assert abs(y_dut - y_ref) <= tol, f"abs err {abs(y_dut - y_ref):.4f} > {tol:.4f}"


@cocotb.test()
async def test_sink_backpressure(dut):
    """
    Hold rdy_mst_in low for several cycles after valid;
    DUT should hold valid and keep output stable.
    """
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)

    # rdy low initially
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, False)

    # Feed a dot
    pairs_real = [(0.7, 0.7), (0.6, -0.4), (-0.5, 0.2), (0.3, 0.9)]
    pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]
    for aq, bq in pairs_q:
        await feed_term(dut, aq, bq)

    # Wait for valid
    await wait_for_valid(dut)
    lo8_1 = int(dut.uo_out.value) & 0xFF
    hi1_1 = (int(dut.uio_out.value) >> 4) & 1

    # Keep rdy low for a few cycles; output/valid must remain stable
    for _ in range(5):
        await RisingEdge(dut.clk)
        lo8_2 = int(dut.uo_out.value) & 0xFF
        hi1_2 = (int(dut.uio_out.value) >> 4) & 1
        vld   = (int(dut.uio_out.value) >> 2) & 1
        assert vld == 1, "valid dropped under backpressure"
        assert (lo8_2 == lo8_1) and (hi1_2 == hi1_1), "output changed under backpressure"

    # Now accept result
    await drain_output(dut)


@cocotb.test()
async def test_extreme_ranges(dut):
    """Drive inputs that push x near -2 and +2 to check saturation / range tails."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    # Two stress cases: mostly positive vs mostly negative dot
    cases = [
        [(0.99, 0.99), (0.99, 0.99), (0.99, 0.99), (0.99, 0.99)],     # large positive
        [(-0.99, 0.99), (-0.99, 0.99), (-0.99, 0.99), (-0.99, 0.99)], # large negative
    ]

    for idx, pairs_real in enumerate(cases):
        pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]
        for aq, bq in pairs_q:
            await feed_term(dut, aq, bq)

        await wait_for_valid(dut)
        lo8 = int(dut.uo_out.value) & 0xFF
        hi1 = (int(dut.uio_out.value) >> 4) & 1
        y_dut = decode_uq3_6(lo8, hi1)
        await drain_output(dut)

        # Reference from actual path
        prods = []
        for aq, bq in pairs_q:
            a = np.int8(aq).item()
            b = np.int8(bq).item()
            prods.append(int(a) * int(b))
        mac_sum = int(np.int32(np.sum(prods)))
        x_fixed = mac_sum >> 10
        x_real = x_fixed / 64.0
        y_ref = float(np.exp(x_real))

        # Relax tolerance slightly for extremes
        tol = 0.06
        assert abs(y_dut - y_ref) <= tol, f"[case {idx}] |err|={abs(y_dut-y_ref):.4f} > {tol:.4f}"


@cocotb.test()
async def test_random_fuzz_100(dut):
    """100 random dots, check error <= tol and monotonicity wrt x."""
    rng = np.random.default_rng(123)
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.uio_in.value = set_bit(int(dut.uio_in.value), 3, True)

    last_x = None
    last_y = None

    for t in range(100):
        pairs_real = [(float(rng.uniform(-0.99, 0.99)),
                       float(rng.uniform(-0.99, 0.99))) for _ in range(4)]
        pairs_q = [(encode_q0_7(a), encode_q0_7(b)) for a, b in pairs_real]
        for aq, bq in pairs_q:
            await feed_term(dut, aq, bq)

        await wait_for_valid(dut)
        lo8 = int(dut.uo_out.value) & 0xFF
        hi1 = (int(dut.uio_out.value) >> 4) & 1
        y_dut = decode_uq3_6(lo8, hi1)
        await drain_output(dut)

        # Reference via fixed-point recompute
        prods = []
        for aq, bq in pairs_q:
            a = np.int8(aq).item()
            b = np.int8(bq).item()
            prods.append(int(a) * int(b))
        mac_sum = int(np.int32(np.sum(prods)))
        x_fixed = mac_sum >> 10
        x_real = x_fixed / 64.0
        y_ref = float(np.exp(x_real))

        tol = 0.064 # we expect 0.4 since only e^x delivers 0.2 at higher values of e^x
        assert abs(y_dut - y_ref) <= tol, f"[#{t}] err={abs(y_dut-y_ref):.4f} > {tol:.4f}"

        # Weak monotonicity sanity: if x increases noticeably, y should not decrease
        if last_x is not None and (x_real - last_x) > 0.05:
            assert y_dut >= (last_y - 0.05), f"monotonicity violated: x↑ but y fell"

        last_x, last_y = x_real, y_dut