# AlarmClockSimple – On‑Chain Alarms and Recurring Timers with HIP‑1215

> A minimal demo showing how a smart contract on **Hedera** can schedule its own future calls using the **Hedera Schedule Service system contract** and **HIP‑1215** – something that is not natively possible on most other EVM chains.

---

## 1. Overview

`AlarmClockSimple` is a very small smart contract that behaves like an **on‑chain alarm clock**:

- Users call `setAlarm(recurring, intervalSeconds)`.
- The contract uses **HIP‑1215** to **schedule a future contract call** to `triggerAlarm(alarmId)` at roughly `now + intervalSeconds`.
- When that time arrives, the **Hedera network itself** executes the scheduled call, without any off‑chain bots.
- If the alarm is **recurring**, `triggerAlarm` will schedule the next run, creating an on‑chain, self‑sustaining timer until the contract runs out of hbar or the scheduling transaction fails for whatever reason.

This demo is designed to be:

- **As simple as possible** while still showing the power of HIP‑1215.
- A concrete example for how to think about **on‑chain cron jobs / timers** on Hedera.

---

## 2. Relevant HIPs and Why This Is Unique

This demo relies on the following Hedera Improvements Proposals(HIPSs):

- [HIP‑755 – Schedule Service System Contract](https://hips.hedera.com/hip/hip-755)  
  Exposes the Hedera Schedule Service as a system contract (address `0x16b`) callable from EVM.
- [HIP‑1215 – Generalized Scheduled Contract Calls](https://hips.hedera.com/hip/hip-1215)  
  **The key one** here. It generalizes HIP‑756 so contracts can schedule **any contract call** via the Schedule Service, including calls to themselves.

### 2.1. How This Compares to Most Other EVM Chains

On most EVM chains (e.g., Ethereum mainnet, many L2s):

- The EVM does not “wake up” on its own.
- A smart contract **cannot schedule** itself to be called later by the protocol.
- Every contract function execution must be triggered by an **externally owned account (EOA)** or some off‑chain system:
  - Cron jobs, bots, keepers, scripts, etc.
- Typical patterns for “timers” require:
  - Storing a deadline in the contract, and
  - Having a bot periodically call `tick()` or `executeIfDue()` to perform actions.

On Hedera with HIP‑1215:

- The network provides a **Schedule Service system contract** at a fixed address (`0x16b`).
- Contracts can call this system contract to create **scheduled transactions**:
  - “At time T, call `myContract.myFunction(args...)` with gasLimit G and value V.”
- The Scheduled transaction is stored by the **Hedera consensus layer**.
- When the scheduled time and signature conditions are met, the network automatically executes it.

This is a **fundamental difference** in capabilities:

- You can build **on‑chain cron jobs** that:
  - Do not rely on off‑chain bots.
  - Are driven entirely by the protocol’s scheduling + execution.

`AlarmClockSimple` is a minimal example of this power.

---

## 3. Contract Source

For reference, refer to [AlarmClock.sol](./1AlarmClock.sol) contract used in this demo:

---

## 4. How It Works Under the Hood

### 4.1. The Hedera Schedule Service System Contract (`HSS`)

At the top of the contract:

```solidity
address internal constant HSS = address(0x16b);
```

- `HSS` (`0x16b`) is the **Schedule Service system contract** (HIP‑755 / HIP‑1215).
  - Exposes:
    - `scheduleCall(...)`
    - `scheduleCallWithPayer(...)`
    - `executeCallOnPayerSignature(...)`
    - `deleteSchedule(...)`
    - `hasScheduleCapacity(...)`

In `AlarmClockSimple`, we only use `scheduleCall(...)`.

### 4.2. Scheduling an Alarm (Creating a Future Contract Call)

When a user calls:

```solidity
setAlarm(bool recurring, uint256 intervalSeconds)
```

we do:

1. Compute the alarm time as:

   ```solidity
   uint256 alarmTime = block.timestamp + intervalSeconds;
   ```

   This is the **desired future time**, expressed in seconds.

2. Store the alarm in contract storage:

   ```solidity
   alarms[alarmId] = Alarm({
       user: msg.sender,
       time: alarmTime,
       numTimesTriggered: 0,
       recurring: recurring,
       interval: intervalSeconds
   });
   ```

3. Call `_scheduleAlarm(alarmId, alarmTime)`.

Inside `_scheduleAlarm`:

```solidity
bytes memory callData = abi.encodeWithSelector(
    this.triggerAlarm.selector,
    alarmId
);
```

We build the ABI‑encoded call data for:

```solidity
triggerAlarm(alarmId)
```

Then we call the Schedule Service:

```solidity
(bool ok, bytes memory result) = HSS.call(
    abi.encodeWithSelector(
        IHederaScheduleService1215.scheduleCall.selector,
        address(this),              // to
        time,                       // expirySecond
        SCHEDULED_CALL_GAS_LIMIT,   // gasLimit
        0,                          // value (HBAR)
        callData                    // encoded triggerAlarm(alarmId)
    )
);
```

Under the hood, the node:

- Validates `time` against the current consensus time and maximum allowed future time.
- Checks that `SCHEDULED_CALL_GAS_LIMIT` is within allowed per‑tx / per‑second limits.
- Checks per‑second **gas throttles** (capacity) for that `time`.
- If valid and not saturated, creates and stores a **scheduled transaction**.

The scheduled transaction is:

> At `expirySecond = time`, perform a `CALL` to `address(this)` with `data = triggerAlarm(alarmId)` and `gasLimit = 2_000_000`.

The system returns:

- `responseCode = 22 (SUCCESS)`, and
- `scheduleAddress` (not used in this simple demo beyond the check).

We then emit ```event AlarmScheduled(uint256 alarmId, uint256 time)``` for users to see in the explorer.

### 4.3. Execution: The Network Calls `triggerAlarm`

When consensus time reaches/exceeds `time` and all necessary conditions are satisfied:

- The **network executes the scheduled tx**.
- From the contract’s point of view, it’s as if someone called:

  ```solidity
  AlarmClockSimple(triggerAlarm(alarmId))
  ```

**But no external caller is required.** This is the crucial distinction: the call originates from the **scheduled transaction managed by the node**, not from an EOA/bot.

Inside `triggerAlarm`:

```solidity
Alarm storage alarm = alarms[alarmId];

// Only the alarm owner and this contract can trigger the alarm
require(msg.sender == address(this) || msg.sender == alarm.user, "Not authorized");

// One-shot alarm can only fire once
require(alarm.recurring || alarm.numTimesTriggered == 0, "Already triggered");

alarm.numTimesTriggered += 1;
emit AlarmTriggered(
    alarmId,
    alarm.user,
    block.timestamp,
    alarm.numTimesTriggered
);
```

- For a one‑shot alarm:
  - It ensures the alarm fires only once.
- For recurring alarms:
  - It increments `numTimesTriggered`.
- In all cases:
  - It emits `AlarmTriggered`, which you can view in the explorer.

If `alarm.recurring == true`, we then reschedule:

```solidity
if (alarm.recurring) {
    alarm.time = alarm.time + alarm.interval;
    _scheduleAlarm(alarmId, alarm.time);
}
```

This means each time the alarm fires, it schedules its next occurrence. The result is a **fully on‑chain recurring timer**, powered by HIP‑1215.

---

## 5. Deployment and Funding

### 5.1. Deploying the Contract

You can deploy `AlarmClockSimple` via:

- Hardhat / Foundry
- Any EVM tooling connected to Hedera testnet/mainnet

Once deployed, note the contract address, e.g.:

- Contract address: `0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75`
- Example explorer links:

  - [View contract on explorer](https://hashscan.io/testnet/contract/0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75)
  - [View contract code](https://hashscan.io/testnet/contract/0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75/source)
  - [View contract calls](http://hashscan.io/testnet/contract/0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75/calls)
  - [View contract events](https://hashscan.io/testnet/contract/0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75/events)

### 5.2. Does the Contract Need HBAR?

**Yes. This contract must hold HBAR.**

Key points:

- Every time a scheduled transaction is executed (i.e., when `triggerAlarm(alarmId)` is called automatically by the network at the scheduled time), **someone must pay for gas and fees**.
- In this demo, the **payer is the contract itself**:
  - The gas cost of the scheduled execution is **deducted from the contract’s HBAR balance**.
  - If `triggerAlarm` reschedules another call (for recurring alarms), that subsequent `_scheduleAlarm` also consumes gas/fees that must be paid.
- If the contract **does not have enough HBAR**:
  - The scheduled execution will fail, typically with an error indicating insufficient funds.
  - For recurring alarms, this means:
    - As soon as any scheduled execution fails (because the contract runs out of HBAR or for any other reason), the cron job effectively stops.
    - The next alarm will **not** be scheduled successfully.
    - To resume, you must:
      1. Re‑fund the contract with enough HBAR.
      2. Call `setAlarm` again to start a new scheduled chain.

Practically:

- After deployment, you should send some HBAR to the contract:

  ```text
  send HBAR → 0xYourAlarmClockSimpleAddress
  ```

- The amount depends on:
  - Your `SCHEDULED_CALL_GAS_LIMIT`.
  - How many times you expect alarms to fire.

---

## 6. Interacting with the Contract

### 6.1. `setAlarm(bool recurring, uint256 intervalSeconds)`

**Purpose:** Create a new one‑shot or recurring alarm.

**Parameters:**

- `recurring`:
  - `false` → one‑shot alarm (fires only once).
  - `true` → recurring alarm (re‑schedules itself).
- `intervalSeconds`:
  - Time in seconds from “now” to the first alarm.
  - Also used as the period for recurring alarms.

**What happens:**

1. Contract creates an `Alarm` struct in storage.
2. Calls HIP‑1215 `scheduleCall` to schedule `triggerAlarm(alarmId)` at about `now + intervalSeconds`.
3. Emits `AlarmScheduled(alarmId, time)`.

**Explorer links (examples):**

- [Call `setAlarm` (one‑shot)](https://hashscan.io/testnet/transaction/1763298348.899059000)
  - [Scheduled `triggerAlarm` Transaction](https://hashscan.io/testnet/transaction/1763298362.119697542)
- [Call `setAlarm` (recurring)](https://hashscan.io/testnet/transaction/1763295671.113653311)
  - [Scheduled `triggerAlarm` #1](https://hashscan.io/testnet/transaction/1763295686.132714004)
  - [Scheduled `triggerAlarm` #2](https://hashscan.io/testnet/transaction/1763295701.092561004)

**Example usage:**

- One‑shot alarm in 60 seconds:

  ```solidity
  setAlarm(false, 60);
  ```

- Recurring alarm every 120 seconds:

  ```solidity
  setAlarm(true, 120);
  ```

### 6.2. `_scheduleAlarm(uint256 alarmId, uint256 time)` (internal)

You don’t call this directly, but it’s important to understand:

- It builds `callData = triggerAlarm(alarmId)`.
- It calls `HSS.scheduleCall(...)`.
- It checks `responseCode` for success.
- It emits `AlarmScheduled`.

### 6.3. `triggerAlarm(uint256 alarmId)`

**Purpose:** Called by the **scheduled transaction** when the alarm fires.

- For one‑shot alarms:
  - Checks that it hasn’t been triggered before.
- For all alarms:
  - Increments `numTimesTriggered`.
  - Emits `AlarmTriggered(alarmId, user, block.timestamp, numTimesTriggered)`.

If `recurring`:

- Updates `alarm.time` to the next interval.
- Calls `_scheduleAlarm` again.

You don’t normally call this function manually; it is meant to be invoked by the HIP‑1215 scheduled tx. For debugging, you can call it yourself and see events, but that bypasses the “scheduled” semantics.

---

## 7. Typical End‑to‑End Flow

Here’s how a full run might look:

1. **Deploy `AlarmClockSimple`.**

   - [Deployment tx](https://hashscan.io/testnet/transactionsById/0.0.902-1763295404-351593479)
   - [Contract address](https://hashscan.io/testnet/contract/0x4a043d8dfe2a9474f21ca9bb7858f885f4f60b75)

2. **User calls `setAlarm(false, 15)`** for a one‑shot alarm in 15 seconds.

   - Tx: [call `setAlarm`](https://hashscan.io/testnet/transaction/1763298348.899059000)
   - Event: `AlarmScheduled(alarmId=0, time≈now+15)`

3. **Network stores scheduled tx:**

   - `scheduleCall(this, time, gasLimit, 0, triggerAlarm(0))`.

4. **After ~15 seconds, the scheduled tx fires:**

   - The Schedule Service triggers `triggerAlarm(0)` on the contract.
   - Tx: [scheduled execution tx](https://hashscan.io/testnet/transaction/1763298362.119697542)
   - Event: `AlarmTriggered(alarmId=0, user=0xUser, time≈now+15, numTimesTriggered=1)`

5. If it had been recurring (`setAlarm(true, 15)`):
   - `triggerAlarm` would also call `_scheduleAlarm` again.
   - You’d see:
     - Another `AlarmScheduled` event for the next run.
     - Another scheduled transaction that will fire ~60 seconds later.
   - This repeats until you alter the contract logic to stop it.

---

## 8. Extending This Demo

This simple alarm clock just emits events. To showcase more of HIP‑1215’s power, you can extend it to:

- **Send HBAR** to the user when the alarm fires.
- **Interact with ERC20/HTS tokens:**
  - e.g., Every time the alarm fires, transfer some token to the user (DCA / drip).
- **Trigger other contracts:**
  - Use the scheduled call to execute complex workflows at specific times.

Each of these extensions keeps the same core pattern:

1. Build `callData` for a function you want to run later.
2. Call `scheduleCall` (or `scheduleCallWithPayer` / `executeCallOnPayerSignature`) on `0x16b`.
3. The Hedera network stores and later executes that call for you.

---

## 9. Summary

- `AlarmClockSimple` is a minimal but powerful demonstration of **HIP‑1215: Generalized Scheduled Contract Calls**.
- It shows how a contract can:
  - Schedule a call to itself in the future.
  - Rely on the **Hedera Schedule Service** to manage and execute that call.
  - Implement **recurring timers** fully on‑chain, with no off‑chain bots.
- This capability, enabled by HIP‑755 and especially HIP‑1215, is **not available on most EVM chains** today.

By understanding this simple alarm clock, you can build:

- On‑chain cron jobs for DeFi rebalancing
- NFT/HTS vesting with time‑based cliffs
- DAO heartbeats and automated treasury actions
- Complex multi‑step workflows that unfold over time, driven by the protocol itself

All starting from the pattern shown in `AlarmClockSimple`.
