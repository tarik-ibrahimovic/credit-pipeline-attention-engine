# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, NextTimeStep
from cocotb.types import LogicArray


async def wait_bit(sig_vec, bit_index, expected, clk, max_cycles=1000, leave_writable=False):
    """Wait until bit 'bit_index' of packed vector 'sig_vec' equals expected (0/1).
    Samples without extra clocks; only ticks if needed. Returns in a write phase if requested."""
    exp = 1 if expected else 0
    # Build 8-bit masks (adjust width if your bus isn't 8)
    width = len(sig_vec) if hasattr(sig_vec, "__len__") else 8
    mask_val = 1 << bit_index
    exp_val  = (exp << bit_index)
    mask_la = LogicArray(format(mask_val, f"0{width}b"))
    exp_la  = LogicArray(format(exp_val,  f"0{width}b"))

    for _ in range(max_cycles):
        await ReadOnly()
        # Mask away unknowns on other bits; only care about target bit
        if (sig_vec.value & mask_la) == exp_la:
            if leave_writable:
                await NextTimeStep()  # leave ReadOnly so caller can drive
            return
        await RisingEdge(clk)
    raise AssertionError(f"Timeout waiting for {sig_vec._name}[{bit_index}] == {exp}")


@cocotb.test()
async def test_project(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    dut._log.info("Test project behavior")

    # Constant data for predictable accumulation
    dut.ui_in.value = 10

    # Wait for ready bit on uio_out[1] (bit-only wait, GL-safe)
    await wait_bit(dut.uio_out, bit_index=1, expected=1, clk=dut.clk,
                   max_cycles=200, leave_writable=True)

    # Drive TB->DUT valid (uio_in[0]=1) for 8 cycles:
    #   1st: capture a1, 2nd: enter READY, next 6: add 100 each → mac=600 → 88
    for _ in range(8):
        dut.uio_in.value = 0x01
        await ClockCycles(dut.clk, 1)

    await ClockCycles(dut.clk, 1)

    expected = 88
    got = int(dut.uo_out.value)
    assert got == expected, f"uo_out={got}, expected={expected}"
