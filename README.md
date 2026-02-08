# Arcanum

<p align="center">
  <img width="900" alt="Arcanum Cover" src="https://github.com/user-attachments/assets/aac28561-3eb7-4b72-9315-64f8ae473468" />
</p>

**Arcanum** is a privacy-aware swap execution layer built on **Uniswap v4 hooks**.

It introduces **intent-based swaps** that reduce unnecessary information leakage around **when**, **where**, and **how** trades execute — without breaking composability, auditability, or onchain verifiability.

Instead of executing swaps immediately and predictably, users submit **swap intents** that are executed later within onchain-enforced constraints. Execution timing, routing, and liquidity behavior are controlled by protocol rules, making trades harder to front-run, sandwich, or exploit via reactive liquidity.

---

## Why Arcanum

Onchain swaps leak more information than most users realize.

Every immediate swap reveals:

* **When** a user intends to trade
* **Where** liquidity will be accessed
* **How** liquidity is expected to react

This information is routinely exploited by MEV searchers through:

* front-running
* sandwich attacks
* liquidity sniping
* reactive LP positioning

Arcanum reduces this leakage **without hiding state or relying on offchain trust**.

---

## What Arcanum Is (and Is Not)

<p align="center">
  <img width="900" alt="Arcanum Diagram 1" src="https://github.com/user-attachments/assets/17bcc045-a4e0-4a6a-90db-f2fd19d5e6d2" />
</p>

<p align="center">
  <img width="900" alt="Arcanum Diagram 2" src="https://github.com/user-attachments/assets/bc05b411-74b9-4794-9f20-9347cd6f7f3e" />
</p>

### Arcanum **is**:

* A rule-based execution layer on top of Uniswap v4
* Fully onchain and verifiable
* Compatible with existing liquidity and tooling
* Designed to **reduce execution signals**, not hide state

### Arcanum **is not**:

* A private DEX
* A dark pool
* An order book or matching engine
* A zero-knowledge system

Privacy comes from **execution uncertainty**, not secrecy.

---

## Core Features

### Intent-Based Swaps

Users submit swap intents instead of immediate swaps.

Each intent specifies:

* An execution window (block range)
* A minimum delay before execution
* A minimum acceptable output
* A set of allowed pools

Any actor may execute an intent once its constraints are satisfied.

---

### Timing Privacy

* Swaps do **not** execute at submission time
* Execution occurs within a flexible block window
* Exact execution block is unknown at submission

This removes deterministic timing signals relied upon by MEV searchers.

---

### Routing Privacy

* Intents specify multiple allowed pools
* The execution route is selected **at execution time**
* Routing constraints are enforced by hooks, not executors

This prevents reliable pre-simulation of price impact and routing behavior.

---

### Liquidity Shielding

* Liquidity changes are controlled via hooks
* Cooldowns prevent instant LP reactions
* Reduces liquidity sniping and reactive MEV

LP behavior becomes less exploitable without restricting participation.

---

### MEV-Aware by Design

* No trusted executors
* No offchain solvers
* No delta-return permissions
* Router allowlisting enforced at the hook level

All execution rules are enforced fully onchain.

---

## Architecture Overview

Arcanum is built entirely using **Uniswap v4 primitives**.

### Key Components

* **PrivacySwapHook**
  Enforces execution windows, routing rules, and liquidity cooldowns.

* **IntentStore**
  Stores user swap intents and execution constraints.

* **PrivacySwapExecutor**
  Executes one or more intents via `PoolManager.swap`.

* **Swap Router**
  Thin router that forwards swaps into the Uniswap v4 `PoolManager`.

* **Batch Liquidity Router**
  Adds and removes liquidity under hook-enforced rules.

All swaps flow through the Uniswap v4 `PoolManager` and are validated by the same hook instance.

---

## Execution Model

1. User submits a swap intent onchain
2. Intent becomes executable after its minimum delay
3. Any executor may execute the intent within the allowed window
4. Routing and timing constraints are enforced by hooks
5. Swap settles atomically and verifiably

Executors **cannot**:

* execute early
* bypass routing constraints
* choose execution timing arbitrarily

---

## Example Swap Intent

```solidity
SwapIntent({
    startBlock: block.number + 5,
    endBlock: block.number + 20,
    minDelayBlocks: 2,
    allowedPoolIds: [...],
    minAmountOut: 1e18,
    salt: bytes32(0)
});
```

---

## Developer Experience

### Local (Anvil)

```bash
anvil
./cli.sh local
```

Supports:

* Full deployment
* Pool creation
* Multi-LP simulation
* Adversarial liquidity testing
* Batched and deferred swaps

---

### Unichain Sepolia

```bash
PRIVATE_KEY=0x... ./cli.sh testnet
```

Supports:

* Real WETH / USDC pools
* Multi-LP liquidity
* Intent-based swaps
* Onchain execution and routing constraints

---

## What Arcanum Improves

| Signal               | Reduced | Mechanism                  |
| -------------------- | ------- | -------------------------- |
| Execution timing     | ✅       | Deferred execution windows |
| Route predictability | ✅       | Execution-time routing     |
| LP reaction speed    | ✅       | Hook-enforced cooldowns    |
| Verifiability        | ✅       | Fully preserved onchain    |

---

## Known Limitations

* Does not hide total traded volume
* Does not hide final execution price
* Does not eliminate all MEV
* Privacy improves with multiple intents and pools

Arcanum is a **privacy-aware execution primitive**, not a silver bullet.

---

## One-Liner

> **Arcanum brings intent-based privacy to Uniswap v4 swaps — reducing when, where, and how execution signals leak without breaking composability.**

---

## Deployments (Unichain Sepolia)

* **Hook Deployment Tx**
  [https://sepolia.uniscan.xyz/tx/0x27f3ed318d734e6adbac2bd67ca5c20bc8b6a3a1a96a8522093447c15e030124](https://sepolia.uniscan.xyz/tx/0x27f3ed318d734e6adbac2bd67ca5c20bc8b6a3a1a96a8522093447c15e030124)

* **Swap Execution Tx**
  [https://sepolia.uniscan.xyz/tx/0x453be2be5f76cfc89256b452b369bcb348cbb2e68d8ad1bfb9939fc4464956ce](https://sepolia.uniscan.xyz/tx/0x453be2be5f76cfc89256b452b369bcb348cbb2e68d8ad1bfb9939fc4464956ce)

