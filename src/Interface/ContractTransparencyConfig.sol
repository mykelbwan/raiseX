// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ContractTransparencyConfig
/// @notice Defines visibility rules for smart contract events.
/// @dev Used to configure who can see specific events and whether
///      the whole contract is public (TRANSPARENT) or private (PRIVATE).
interface ContractTransparencyConfig {
    /// @notice Defines who an event can be visible to.
    enum Field {
        TOPIC1, // First indexed parameter of the event
        TOPIC2, // Second indexed parameter
        TOPIC3, // Third indexed parameter
        SENDER, // Transaction sender (msg.sender)
        EVERYONE // Public visibility
    }

    /// @notice Defines overall contract visibility mode.
    enum ContractCfg {
        TRANSPARENT, // All data is public
        PRIVATE // Data is hidden, only allowed events are visible
    }

    /// @notice Configuration for a single event’s visibility.
    struct EventLogConfig {
        bytes32 eventSignature; // Hash of the event signature
        Field[] visibleTo; // Who is allowed to view this event
    }

    /// @notice Full visibility configuration for the contract.
    struct VisibilityConfig {
        ContractCfg contractCfg; // Contract visibility mode
        EventLogConfig[] eventLogConfigs; // List of per-event rules
    }

    /// @notice Returns the contract’s visibility rules.
    function visibilityRules() external pure returns (VisibilityConfig memory);
}
