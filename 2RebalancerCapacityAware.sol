// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Minimal interface for HIP-1215 scheduleCall + hasScheduleCapacity + deleteSchedule
interface IHederaScheduleService1215Full {
    function scheduleCall(
        address to,
        uint256 expirySecond,
        uint256 gasLimit,
        uint64 value,
        bytes calldata callData
    ) external returns (int64 responseCode, address scheduleAddress);

    function deleteSchedule(
        address scheduleAddress
    ) external returns (int64 responseCode);

    function hasScheduleCapacity(
        uint256 expirySecond,
        uint256 gasLimit
    ) external view returns (bool hasCapacity);
}

/// PRNG system contract interface (Hedera)
interface IPrngSystemContract {
    function getPseudorandomSeed() external returns (bytes32 seedBytes);
}

/// Response codes (subset) from Hedera
library HederaResponseCodesLib {
    int64 constant SUCCESS = 22;
}

/// Capacity-aware "rebalancer"
/// -----------------------------------
///
/// Concept:
/// - Pretend this contract manages a DeFi "vault."
/// - It wants to call rebalance() periodically, but:
///   - It uses hasScheduleCapacity() to find a second that has scheduling capacity.
///   - It schedules a future call to rebalance() at that second using scheduleCall().
///   - It stores the scheduleAddress so it can cancel the next rebalance via deleteSchedule().
///
/// This demo showcases:
/// - scheduleCall(...)
/// - hasScheduleCapacity(...)
/// - deleteSchedule(...)
/// - An exponential back-off + jitter retry pattern using Hedera PRNG.
contract RebalancerCapacityAware {
    // Hedera Schedule Service system contract address (HIP-755/1215)
    address internal constant HSS = address(0x16b);
    // Hedera PRNG system contract address (HIP-351)
    address internal constant PRNG = address(0x169);

    // Gas limit to use for scheduled rebalances (must cover rebalance() and rescheduling)
    uint256 internal constant REBALANCE_GAS_LIMIT = 1_500_000;

    struct RebalancingConfig {
        bool active;
        uint256 intervalSeconds;
        uint256 lastRebalanceTime;
        uint256 rebalanceCount;
        address lastScheduleAddress;
    }

    RebalancingConfig public config;

    event RebalancingStarted(uint256 intervalSeconds, uint256 firstAt);
    event RebalancingStopped();
    event RebalanceScheduled(
        uint256 scheduledAt,
        uint256 desiredAt,
        address scheduleAddress
    );
    event RebalanceExecuted(uint256 timestamp, uint256 rebalanceCount);

    /// Start the capacity-aware rebalancing loop.
    /// intervalSeconds: desired time between rebalances.
    function startRebalancing(uint256 intervalSeconds) external {
        require(intervalSeconds > 0, "interval must be > 0");
        require(!config.active, "already active");

        config.active = true;
        config.intervalSeconds = intervalSeconds;
        config.lastRebalanceTime = block.timestamp;
        config.rebalanceCount = 0;

        // Schedule the first rebalance
        uint256 desiredTime = block.timestamp + intervalSeconds;
        uint256 scheduledAt = _scheduleNextRebalance(desiredTime);
        emit RebalancingStarted(intervalSeconds, scheduledAt);
    }

    /// Stop future rebalances (if there is a scheduled one, cancel it).
    function stopRebalancing() external {
        // If there's an active scheduled rebalance, cancel it
        if (config.lastScheduleAddress != address(0)) {
            address scheduleAddress = config.lastScheduleAddress;

            (bool ok, ) = HSS.call(
                abi.encodeWithSelector(
                    IHederaScheduleService1215Full.deleteSchedule.selector,
                    scheduleAddress
                )
            );
            require(ok, "deleteSchedule system call failed");
            // We intentionally ignore the decoded responseCode for this demo:
            // But in production, you should probably handle it accordingly
            // int64 rc = abi.decode(result, (int64));

            // Clear the stored schedule address regardless of status code
            config.lastScheduleAddress = address(0);
        }

        // Mark the loop as inactive so rebalance() won't schedule new ones
        config.active = false;
        emit RebalancingStopped();
    }

    /// Internal helper: find a capacity-friendly second and schedule rebalance().
    /// Returns the chosen second.
    function _scheduleNextRebalance(
        uint256 desiredTime
    ) internal returns (uint256 chosenTime) {
        // Find a second that has capacity for our gas limit.
        chosenTime = _findAvailableSecond(
            desiredTime,
            REBALANCE_GAS_LIMIT,
            8 // maxProbes
        );

        bytes memory callData = abi.encodeWithSelector(this.rebalance.selector);

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

    /// Get a pseudorandom seed from the Hedera PRNG system contract.
    function _getSeed() internal returns (bytes32 seedBytes) {
        (bool success, bytes memory result) = PRNG.call(
            abi.encodeWithSelector(
                IPrngSystemContract.getPseudorandomSeed.selector
            )
        );
        require(success, "PRNG system call failed");
        seedBytes = abi.decode(result, (bytes32));
    }

    /// Capacity-aware finder using hasScheduleCapacity() and exponential back-off + jitter.
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

    /// This is the function that is called by the scheduled transaction.
    /// It simulates a "rebalance" (we just increment a counter).
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
}
