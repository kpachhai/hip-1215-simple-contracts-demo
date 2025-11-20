// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Minimal interface for HIP-1215 scheduleCall
interface IHederaScheduleService1215 {
    function scheduleCall(
        address to,
        uint256 expirySecond,
        uint256 gasLimit,
        uint64 value,
        bytes memory callData
    ) external returns (int64 responseCode, address scheduleAddress);
}

library HederaResponseCodesLib {
    int64 constant SUCCESS = 22;
}

/// Very simple "alarm clock" demo:
/// - User calls setAlarm()
/// - Contract schedules a call to triggerAlarm(alarmId) at roughly now + intervalSeconds
/// - No off-chain bots required
contract AlarmClockSimple {
    // Hedera Schedule Service system contract
    address internal constant HSS = address(0x16b);

    // Gas limit used for scheduled calls (must cover triggerAlarm + re-scheduling logic)
    uint256 internal constant SCHEDULED_CALL_GAS_LIMIT = 2_000_000;

    struct Alarm {
        address user;
        uint256 time;              // when we expect it to fire
        uint256 numTimesTriggered; // how many times this alarm has fired
        bool recurring;
        uint256 interval;          // seconds between firings (for recurring alarms)
    }

    uint256 public nextAlarmId;
    mapping(uint256 => Alarm) public alarms;

    event AlarmScheduled(uint256 alarmId, uint256 time);
    event AlarmTriggered(uint256 alarmId, address user, uint256 time, uint256 numTimesTriggered);

    /// Funds will be used to pay the cost of executing the triggerAlarm function
    /// and to schedule another timer in case of recurrent alarm.
    constructor() payable { }
    receive() external payable { }

    /// User calls this to set a one-shot or recurring alarm.
    /// For simplicity we choose time = block.timestamp + intervalSeconds.
    function setAlarm(bool recurring, uint256 intervalSeconds) external {
        require(intervalSeconds > 0, "interval must be > 0");

        uint256 alarmId = nextAlarmId++;
        uint256 alarmTime = block.timestamp + intervalSeconds;

        alarms[alarmId] = Alarm({
            user: msg.sender,
            time: alarmTime,
            numTimesTriggered: 0,
            recurring: recurring,
            interval: intervalSeconds
        });

        _scheduleAlarm(alarmId, alarmTime);
    }

    function _scheduleAlarm(uint256 alarmId, uint256 time) internal {
        // Encode the future call: triggerAlarm(alarmId)
        bytes memory callData = abi.encodeWithSelector(
            this.triggerAlarm.selector,
            alarmId
        );

        // Ask HIP-1215 Schedule Service to schedule this call
        (bool ok, bytes memory result) = HSS.call(
            abi.encodeWithSelector(
                IHederaScheduleService1215.scheduleCall.selector,
                address(this),              // call back into this contract
                time,                       // expirySecond
                SCHEDULED_CALL_GAS_LIMIT,   // gasLimit for the future call
                0,                          // no HBAR value sent
                callData
            )
        );

        (int64 rc, ) = ok
            ? abi.decode(result, (int64, address))
            : (int64(0), address(0));
        require(rc == HederaResponseCodesLib.SUCCESS, "Schedule failed");

        emit AlarmScheduled(alarmId, time);
    }

    /// This is called automatically by the network when the scheduled time arrives.
    function triggerAlarm(uint256 alarmId) external {
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

        // If recurring, reschedule for the next interval
        if (alarm.recurring) {
            alarm.time = alarm.time + alarm.interval;
            _scheduleAlarm(alarmId, alarm.time);
        }
    }   
}
