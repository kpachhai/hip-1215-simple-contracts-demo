# RebalancerCapacityAware – Capacity‑Aware On‑Chain Rebalancing with HIP‑1215

> An intermediate demo showing how a smart contract on **Hedera** can build a self‑scheduling **DeFi‑style “rebalancer”** that respects network capacity using `hasScheduleCapacity`, `scheduleCall`, and `deleteSchedule` from **HIP‑1215** – something that is not natively possible on most other EVM chains.

---

## 1. Overview

`RebalancerCapacityAware` is a small smart contract that behaves like an **on‑chain DeFi vault rebalancer**:

- Users call `startRebalancing(intervalSeconds)`.
- The contract uses **HIP‑1215** to:
  - Ask the network if a given future second has capacity for a scheduled call (`hasScheduleCapacity`).
  - Use an **exponential back‑off + jitter** strategy to find a “good” second near the desired time.
  - **Schedule a future contract call** to `rebalance()` at that second using `scheduleCall`.
- When that time arrives, the **Hedera network itself** executes `rebalance()`, without any off‑chain bots.
- Each `rebalance()` call:
  - Increments an internal counter (simulating a “rebalance” operation).
  - Immediately schedules the **next** rebalance, again using capacity‑aware scheduling.
- Users can call `stopRebalancing()` to cancel the current scheduled task and mark the loop as inactive.

This is what the demo does:

- It uses both `scheduleCall` and `hasScheduleCapacity`.
- It introduces a **retry/back‑off pattern** taken from HIP‑1215.
- It shows how to cancel the next scheduled action.
- Shows a concrete example for how to think about **capacity‑aware, on‑chain cron jobs** on Hedera.

---

## 2. Relevant HIPs and Why This Is Unique

This demo relies on the following Hedera Improvement Proposals(HIPs):

- [HIP‑755 – Schedule Service System Contract](https://hips.hedera.com/hip/hip-755)  
  Exposes the Hedera Schedule Service as a system contract (address `0x16b`) callable from EVM.
- [HIP‑351 – Pseudorandom Number Generator System Contract](https://hips.hedera.com/hip/hip-351)  
  Exposes a PRNG system contract (address `0x169`) to get pseudorandom seeds.
- [HIP‑1215 – Generalized Scheduled Contract Calls](https://hips.hedera.com/hip/hip-1215)  
  **The key one** here. It lets contracts:
  - Schedule arbitrary contract calls in the future (`scheduleCall`, `scheduleCallWithPayer`, `executeCallOnPayerSignature`).
  - Query if a given future second has capacity (`hasScheduleCapacity`).
  - Delete scheduled transactions (`deleteSchedule`).

### 2.1. How This Compares to Most Other EVM Chains

On most EVM chains (e.g., Ethereum mainnet, many L2s):

- The EVM does not “wake up” on its own.
- A smart contract **cannot schedule** itself to be called later by the protocol.
- Every contract function execution must be triggered by an **externally owned account (EOA)** or some off‑chain system:
  - Cron jobs, bots, keepers, scripts, etc.
- Typical patterns for “timers” require:
  - Storing a deadline in the contract, and
  - Having a bot periodically call `tick()` or `executeIfDue()` to perform actions.
- A contract cannot ask:
  - “Will there be enough capacity/gas budget at time T for this future transaction?”
  - “Please store a future call to `myContract.myFunction(...)` at/after time T.”
- Capacity and rate limiting are enforced at node/mempool level, but contracts themselves cannot **query** or **participate** in scheduling at the protocol level.
- DeFi automation (like rebalancing) typically requires off‑chain agents (keepers/bots) plus heuristics about **when** to run.

On Hedera with HIP‑1215:

- The network provides a **Schedule Service system contract** at a fixed address (`0x16b`).

  - Contracts can call this system contract to create **scheduled transactions**:
    - “At time T, call `myContract.myFunction(args...)` with gasLimit G and value V.”
  - Query **future capacity** via `hasScheduleCapacity(expirySecond, gasLimit)`.
  - Schedule future calls via `scheduleCall(...)`.
  - Cancel scheduled calls via `deleteSchedule(...)`.
  - The Scheduled transaction is stored by the **Hedera consensus layer**.
  - When the scheduled time and signature conditions are met, the network automatically executes it.

- The **PRNG system contract** at `0x169` (HIP‑351) lets contracts add random jitter to avoid “stampeding” into the same second.

This enables **capacity‑aware on‑chain automation**, where:

- The contract itself cooperates with the network throttling model.
- It can choose a nearby “less busy” second for its scheduled work.
- It doesn’t require off‑chain capacity probing or manual scheduling.

`RebalancerCapacityAware` is a focused example of this power.

---

## 3. Contract Source

For reference, refer to [RebalancerCapacityAware.sol](./2RebalancerCapacityAware.sol) contract used in this demo:

---

## 4. How It Works Under the Hood

### 4.1. The Hedera Schedule Service and PRNG System Contracts

At the top of the contract:

```solidity
address internal constant HSS = address(0x16b);
address internal constant PRNG = address(0x169);
```

- `HSS` (`0x16b`) is the **Schedule Service system contract** (HIP‑755 / HIP‑1215).
  - Exposes:
    - `scheduleCall(...)`
    - `scheduleCallWithPayer(...)`
    - `executeCallOnPayerSignature(...)`
    - `deleteSchedule(...)`
    - `hasScheduleCapacity(...)`
- `PRNG` (`0x169`) is the **PRNG system contract** (HIP‑351).
  - Exposes:
    - `getPseudorandomSeed() returns (bytes32)`

In `RebalancerCapacityAware`, we use:

- `scheduleCall(...)` to schedule future rebalances.
- `hasScheduleCapacity(...)` to probe if a given second can accept a scheduled call with a particular gas limit.
- `deleteSchedule(...)` to cancel the next scheduled rebalance.
- `getPseudorandomSeed()` to add **jitter** to our capacity probing.

---

### 4.2. Starting the Rebalancing Loop

When a user calls:

```solidity
startRebalancing(uint256 intervalSeconds)
```

we do:

1. Validate and mark config as active:

   ```solidity
   require(intervalSeconds > 0, "interval must be > 0");
   require(!config.active, "already active");

   config.active = true;
   config.intervalSeconds = intervalSeconds;
   config.lastRebalanceTime = block.timestamp;
   config.rebalanceCount = 0;
   ```

2. Choose an **ideal** time for the first rebalance:

   ```solidity
   uint256 desiredTime = block.timestamp + intervalSeconds;
   ```

3. Schedule the first rebalance:

   ```solidity
   uint256 scheduledAt = _scheduleNextRebalance(desiredTime);
   emit RebalancingStarted(intervalSeconds, scheduledAt);
   ```

So `startRebalancing` does not directly call `rebalance()`; it asks HIP‑1215 to call `rebalance()` in the future.

---

### 4.3. Capacity‑Aware Scheduling with `_findAvailableSecond`

The core of this demo lives in `_scheduleNextRebalance` and `_findAvailableSecond`.

#### `_scheduleNextRebalance(desiredTime)`

```solidity
function _scheduleNextRebalance(uint256 desiredTime)
    internal
    returns (uint256 chosenTime)
{
    // Find a second that has capacity for our gas limit.
    chosenTime = _findAvailableSecond(
        desiredTime,
        REBALANCE_GAS_LIMIT,
        8 // maxProbes
    );

    bytes memory callData = abi.encodeWithSelector(
        this.rebalance.selector
    );

    (bool ok, bytes memory result) = HSS.call(
        abi.encodeWithSelector(
            IHederaScheduleService1215Full.scheduleCall.selector,
            address(this),
            chosenTime,
            REBALANCE_GAS_LIMIT,
            0,
            callData
        )
    );

    (int64 rc, address scheduleAddress) = ok
        ? abi.decode(result, (int64, address))
        : (int64(0), address(0));
    require(rc == HederaResponseCodesLib.SUCCESS, "scheduleCall failed");

    // Remember the schedule so we can optionally cancel it.
    config.lastScheduleAddress = scheduleAddress;

    emit RebalanceScheduled(chosenTime, desiredTime, scheduleAddress);
}
```

Steps:

1. Call `_findAvailableSecond` to get `chosenTime` (near `desiredTime`).
2. Build `callData` for a future call to `rebalance()`.
3. Call `HSS.scheduleCall(this, chosenTime, REBALANCE_GAS_LIMIT, 0, callData)`.
4. Decode `(responseCode, scheduleAddress)`:
   - If `responseCode != SUCCESS (22)`, revert with `"scheduleCall failed"`.
5. Save `scheduleAddress` in `config.lastScheduleAddress` so we can later cancel it.
6. Emit `RebalanceScheduled`.

#### `_findAvailableSecond(expiry, gasLimit, maxProbes)`

```solidity
function _findAvailableSecond(
    uint256 expiry,
    uint256 gasLimit,
    uint256 maxProbes
) internal returns (uint256 second) {
    IHederaScheduleService1215Full svc = IHederaScheduleService1215Full(
        HSS
    );

    if (svc.hasScheduleCapacity(expiry, gasLimit)) {
        return expiry;
    }

    // Use Hedera PRNG
    bytes32 seed = _getSeed();
    for (uint256 i = 0; i < maxProbes; i++) {
        uint256 baseDelay = 1 << i; // 1, 2, 4, 8, ...
        bytes32 h = keccak256(abi.encodePacked(seed, i));
        uint16 r = uint16(uint256(h)); // take low 16 bits
        uint256 jitter = uint256(r) % baseDelay;
        uint256 candidate = expiry + baseDelay + jitter;
        if (svc.hasScheduleCapacity(candidate, gasLimit)) {
            return candidate;
        }
    }
    revert("No capacity after maxProbes");
}
```

- First check the **ideal** second `expiry`:
  - If `hasScheduleCapacity(expiry, gasLimit)` returns `true`, use it.
- Otherwise:

  - Get a pseudorandom 32‑byte seed from the PRNG:

    ```solidity
    bytes32 seed = _getSeed();
    ```

  - For `i = 0..maxProbes-1`:
    - Compute `baseDelay = 2^i`, giving `1, 2, 4, 8, ...`.
    - Hash `seed` with `i` to get `h = keccak256(seed, i)`.
    - Take low 16 bits of `h` and reduce modulo `baseDelay` to get `jitter`.
    - Candidate second = `expiry + baseDelay + jitter`.
    - Check `hasScheduleCapacity(candidate, gasLimit)`:
      - If `true`, return `candidate`.

- If no suitable second is found, it reverts.

This is a Hedera‑adapted version of the exponential back‑off + jitter pattern recommended by HIP‑1215, using **Hedera’s PRNG**.

---

### 4.4. Execution: The Network Calls `rebalance()`

Once a scheduled rebalance reaches `chosenTime`, and all the usual Schedule Service conditions are satisfied, the network executes the scheduled tx:

- From the contract’s perspective, this looks like a normal call to:

  ```solidity
  RebalancerCapacityAware.rebalance()
  ```

Inside `rebalance()`:

```solidity
function rebalance() external {
    require(config.active, "not active");

    // Update state to reflect this rebalance
    config.rebalanceCount += 1;
    config.lastRebalanceTime = block.timestamp;

    emit RebalanceExecuted(block.timestamp, config.rebalanceCount);

    // Immediately schedule the next rebalance, capacity-aware.
    uint256 desiredTime = block.timestamp + config.intervalSeconds;
    _scheduleNextRebalance(desiredTime);
}
```

- It:
  - Ensures the loop is still active.
  - Increments `rebalanceCount`.
  - Records `lastRebalanceTime`.
  - Emits `RebalanceExecuted`.
- Then it schedules the **next** rebalance:
  - `desiredTime = now + intervalSeconds`.
  - `_scheduleNextRebalance(desiredTime)` uses `hasScheduleCapacity` and `scheduleCall` again.

This creates a **self‑sustaining, capacity‑aware loop** as long as:

- The contract has enough HBAR to pay for scheduled executions.
- `config.active` remains `true`.

---

### 4.5. Stopping / Cancelling

The loop is stopped manually by calling:

```solidity
stopRebalancing()
```

which:

1. If there is a pending schedule:

   ```solidity
   if (config.lastScheduleAddress != address(0)) {
       address scheduleAddress = config.lastScheduleAddress;

       (bool ok, ) = HSS.call(
           abi.encodeWithSelector(
               IHederaScheduleService1215Full.deleteSchedule.selector,
               scheduleAddress
           )
       );
       require(ok, "deleteSchedule system call failed");

       config.lastScheduleAddress = address(0);
   }
   ```

   - This calls `deleteSchedule(scheduleAddress)`.
   - For demo simplicity, it only checks the low‑level `ok` (no EVM revert), not the `responseCode`.
   - It clears `lastScheduleAddress` regardless of the status.

2. Marks the loop as inactive:

   ```solidity
   config.active = false;
   emit RebalancingStopped();
   ```

After this:

- Even if a scheduled `rebalance()` somehow executes (e.g., `deleteSchedule` failed at the HAPI level), the `require(config.active)` prevents it from scheduling further rebalances.

---

## 5. Deployment and Funding

### 5.1. Deploying the Contract

You can deploy `RebalancerCapacityAware` via:

- Hardhat / Foundry
- Any EVM tooling connected to Hedera testnet/mainnet

Once deployed, note the contract address, e.g.:

- Contract address: `0x34dcf612e067f9511e380eb9b673612c351a561a`

Example explorer links:

- [View contract on explorer](https://hashscan.io/testnet/contract/0x34dcf612e067f9511e380eb9b673612c351a561a)
- [View contract code](https://hashscan.io/testnet/contract/0x34dcf612e067f9511e380eb9b673612c351a561a/source)
- [View contract calls](https://hashscan.io/testnet/contract/0x34dcf612e067f9511e380eb9b673612c351a561a/calls)
- [View contract events](https://hashscan.io/testnet/contract/0x34dcf612e067f9511e380eb9b673612c351a561a/events)

### 5.2. Does the Contract Need HBAR?

**Yes. This contract must hold HBAR.**

Key points:

- Each scheduled execution of `rebalance()` is a real transaction with gas and fees.
- In this demo, the **payer is the contract itself**:
  - The gas cost for each scheduled execution is charged against the contract’s HBAR balance.
- Every time `rebalance()` calls `_scheduleNextRebalance`, another `scheduleCall` transaction is created, which also consumes gas/fees at creation time (payer rules apply as configured at the node level).

If the contract runs out of HBAR:

- Future scheduled executions will fail with a code like `INSUFFICIENT_PAYER_BALANCE`.
- The loop will effectively stop when no new schedules can be created.

Practically:

- After deployment, send some HBAR to the contract:

  ```text
  send HBAR → 0x34dcf612e067f9511e380eb9b673612c351a561a
  ```

- The amount you need depends on:
  - `REBALANCE_GAS_LIMIT`.
  - How many rebalances you expect to execute.
  - Network gas price at the time.

---

## 6. Interacting with the Contract

### 6.1. `startRebalancing(uint256 intervalSeconds)`

**Purpose:** Start the capacity‑aware rebalancing loop.

**Parameters:**

- `intervalSeconds`:
  - The desired time between rebalances.
  - Used to compute the “ideal” `desiredTime` for each next rebalance.

**What happens:**

1. Marks `config.active = true`, stores `intervalSeconds`.
2. Computes `desiredTime = now + intervalSeconds`.
3. Calls `_scheduleNextRebalance(desiredTime)`:
   - Uses `hasScheduleCapacity` + back‑off/jitter to find a second.
   - Schedules a future `rebalance()` at that second via `scheduleCall`.
4. Emits `RebalancingStarted(intervalSeconds, scheduledAt)`.

**Example explorer links:**

- [Call `startRebalancing(15)`](https://hashscan.io/testnet/transaction/1763392642.383415448)
- [Call `startRebalancing(30)`](https://hashscan.io/testnet/transaction/1763392803.902837600)

### 6.2. `rebalance()`

**Purpose:** The function called automatically by the scheduled transactions.

You don’t typically call this manually in the demo (except for testing):

- It increments `rebalanceCount`.
- Updates `lastRebalanceTime`.
- Emits `RebalanceExecuted`.
- Schedules the **next** rebalance via `_scheduleNextRebalance`.

But for debugging, you can call it manually:

- That will immediately increment the counter and create a new schedule (capacity‑aware).
- This is exactly what you observed when you manually called `rebalance()` once and saw an “extra” scheduled tx.

### 6.3. `stopRebalancing()`

**Purpose:** Stop the loop and cancel the next scheduled rebalance if possible.

- If `config.lastScheduleAddress != address(0)`:
  - Calls `deleteSchedule(lastScheduleAddress)` on HSS.
  - Clears `lastScheduleAddress`.
- Sets `config.active = false`.
- Emits `RebalancingStopped`.

**Example explorer links:**

- [Call `stopRebalancing()`](https://hashscan.io/testnet/transaction/1763392691.505069000)

---

## 7. Typical End‑to‑End Flow

Here’s how a full run might look:



1. **Deploy `RebalancerCapacityAware` and fund the contract with some HBAR.**

   - This is required so the contract can pay for scheduled executions.
  - [Deployment tx](https://hashscan.io/testnet/transaction/1763392533.997038791)
   - [Contract address](https://hashscan.io/testnet/contract/0x34dcf612e067f9511e380eb9b673612c351a561a)

2. **Call `startRebalancing(15)`** – 15‑second interval.

   - Contract schedules the first `rebalance()` at ~`now + 15`.
   - [Explorer tx – startRebalancing(15)](https://hashscan.io/testnet/transaction/1763392642.383415448)

3. **Three scheduled `rebalance()` executions**

   - Each execution:
     - Increments `rebalanceCount`.
     - Schedules the next `rebalance()` ~15 seconds later (capacity‑aware).
   - In the logs, you see several calls from the system contract account (e.g. `0.0.902` → the schedule execution context) with “None” message (no error).
   - Example entries:

     - `10:18:02.0893` – scheduled `rebalance`
     - `10:17:49.0659` – scheduled `rebalance`
     - `10:17:36.0449` – scheduled `rebalance`

4. **Call `stopRebalancing()`**.

   - This attempts to `deleteSchedule` the current pending rebalance.
   - Set `config.active = false`.
   - No further rebalances are scheduled from this loop.

5. **Call `startRebalancing(30)`** – new loop at 30‑second interval.

   - A new capacity‑aware schedule chain starts with 30‑second spacing.

6. **Five scheduled transactions execute successfully** (new chain).

   - Similar to step 3, but with a 30‑second interval.

7. **Manually call `rebalance()` once.**

   - This immediately:
     - Increments the counter.
     - Creates an **extra** scheduled `rebalance` on top of whatever was already scheduled from the normal loop.
   - Now there are effectively two future scheduled rebalances:
     - One created by a previous scheduled call.
     - One created by our manual call to `rebalance()`.

8. **Next scheduled transaction execute successfully (the already‑scheduled one).**

   - This `rebalance()` runs and schedules yet another future call.
   - Shortly after, the “extra” scheduled `rebalance` from our manual call tries to schedule its own next one.
   - That scheduling fails, giving you:

     ```text
     Error("scheduleCall failed")
     ```

   - In logs, we saw:

     - `10:22:59.2851` – scheduled call success
     - `10:23:01.0771` – `Error("scheduleCall failed")`

   - These two are only ~2 seconds apart, illustrating how different scheduled instances can behave differently depending on capacity/time and the contract’s remaining funds.

9. **A later scheduled transaction succeedes again.**

   - Another previously scheduled `rebalance` runs successfully at `10:23:29.1011`, scheduling its own next call.

10. **The last execution fails due to insufficient balance.**

    - Eventually, the contract runs out of HBAR to pay for scheduled executions.
    - The final failure shows:

      ```text
      INSUFFICIENT_PAYER_BALANCE
      ```

    - At `10:23:59.1486`, we saw:

      - `INSUFFICIENT_PAYER_BALANCE` from `0x0000...0386 (0.0.902)`

This flow is a perfect illustration that:

- Each scheduled `rebalance()` is an independent transaction.
- Failures in one execution (`scheduleCall failed`) don’t retroactively cancel others already scheduled.
- Running out of HBAR eventually stops the automation, as expected.

---

## 8. Extending This Demo

Once you understand `RebalancerCapacityAware`, you can extend the idea to:

- **Real DeFi vaults:**
  - Instead of just incrementing a counter, perform:
    - Price checks.
    - Token swaps via DEXes.
    - Portfolio rebalancing.
- **HTS / ERC20‑aware operations:**
  - Combine capacity‑aware scheduling with actual HTS/ERC20 transfers or liquidity moves.
- **DAO treasury management:**
  - Capacity‑aware “heartbeat” that periodically moves funds or distributes rewards.
- **Service windows:**
  - Use `hasScheduleCapacity` to avoid busy periods and schedule heavy operations in quieter times.

All of these follow the same pattern:

1. Decide **what** to do in `rebalance`/`execute` logic.
2. Use `hasScheduleCapacity` + back‑off/jitter to find a good second.
3. Use `scheduleCall` to schedule your future call.
4. Optionally use `deleteSchedule` to allow cancellation.

---

## 9. Summary

- `RebalancerCapacityAware` demonstrates **capacity‑aware on‑chain automation** using HIP‑1215.
- It shows how a contract can:
  - Ask the network about future capacity (`hasScheduleCapacity`).
  - Use an exponential back‑off + jitter strategy with Hedera’s PRNG to find a less congested second.
  - Schedule its own future work via `scheduleCall`.
  - Cancel the next scheduled action via `deleteSchedule`.
- This capability – having a contract that is aware of future scheduling capacity and can cooperate with the network’s throttling model – is **not available on most EVM chains**.

By understanding this demo, developers can build:

- Smarter DeFi automation that respects network capacity.
- More robust on‑chain jobs that avoid “everyone rebalancing at the exact same second.”
- Safer, more predictable long‑running systems, all coordinated by Hedera’s Schedule Service instead of off‑chain cron infrastructure.
