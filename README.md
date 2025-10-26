![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Tiny Tapeout Verilog Project Template

- [Read the documentation for project](docs/info.md)

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Set up your Verilog project

1. Add your Verilog files to the `src` folder.
2. Edit the [info.yaml](info.yaml) and update information about your project, paying special attention to the `source_files` and `top_module` properties. If you are upgrading an existing Tiny Tapeout project, check out our [online info.yaml migration tool](https://tinytapeout.github.io/tt-yaml-upgrade-tool/).
3. Edit [docs/info.md](docs/info.md) and add a description of your project.
4. Adapt the testbench to your design. See [test/README.md](test/README.md) for more information.

The GitHub action will automatically build the ASIC files using [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/).

## Enable GitHub actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## What next?

- [Submit your design to the next shuttle](https://app.tinytapeout.com/).
- Edit [this README](README.md) and explain your design, how it works, and how to test it.
- Share your project on your social network of choice:
  - LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
  - Mastodon [#tinytapeout](https://chaos.social/tags/tinytapeout) [@matthewvenn](https://chaos.social/@matthewvenn)
  - X (formerly Twitter) [#tinytapeout](https://twitter.com/hashtag/tinytapeout) [@tinytapeout](https://twitter.com/tinytapeout)
  - Bluesky [@tinytapeout.com](https://bsky.app/profile/tinytapeout.com)

# Transformer Attention Engine – TinyML ASIC Project

## Project Proposal

Goal: design, train, and implement the **core attention mechanism** of a Transformer model as a TinyTapeout ASIC.

We will:
1. Design a fixed-point, single-head Transformer Attention Engine in Verilog.
2. Train a small Transformer model in software for a simple sequence or classification task.
3. Extract the learned matrices (`W_Q`, `W_K`, `W_V`) from training.
4. Implement the learned weights directly in hardware using standard cells.
5. If the design exceeds area limits, reduce precision or dimensions. If still too large, explore custom cells.

---

## What the Transformer Does

A Transformer processes sequences using **self-attention** instead of recurrence or convolution.  
For input tokens \(X = [x_1, x_2, ..., x_n]\):

\[
Q = XW_Q,\quad K = XW_K,\quad V = XW_V
\]
\[
\text{Attention}(Q,K,V) = \text{softmax}\!\left(\frac{QK^T}{\sqrt{d_k}}\right)V
\]

Each token attends to all others through this computation.

---

## Hardware Implementation

- Function: \(O = \text{softmax}(QK^T)V\)
- Precision: 8-bit fixed point
- Dimensions: \(d_k = 4, d_v = 1, n = 4\)
- Architecture: serialized, single 8×8→16-bit MAC
- Softmax: LUT-based exponential and reciprocal
- Technology: Sky130 open PDK (TinyTapeout)
- Target: ≤ 1k gates, 10–20 MHz

---

## Implementation Plan (Condensed)

1. **Interface**  
   Define ports: `clk, rst_n, in_data[7:0], in_valid, in_ready, out_data[7:0], out_valid, out_ready`.

2. **Golden Reference**  
   Python fixed-point model, LUT generation (`exp_lut.mem`, `recip_lut.mem`), test vectors.

3. **RTL Core**  
   Modules: `mac8x8.sv`, `lut_exp.sv`, `lut_recip.sv`, `fifo2.sv`, `attn_fsm.sv`.  
   FSM stages: SCORE → SOFTMAX → NORM → WEIGHTED_SUM → OUT.

4. **Simulation**  
   Unit testbenches, full verification vs. Python golden (±1 LSB).

5. **Synthesis**  
   Run `yosys`, reduce LUTs if over area, verify timing.

6. **Integration**  
   TinyTapeout repo structure:  
