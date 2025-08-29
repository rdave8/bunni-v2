// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract Guarded {
    error GuardedCall();

    /// @dev The original address of this contract
    address private immutable original;

    address internal immutable hub;
    address internal immutable hook;
    address private immutable quoter;

    function _guardedCheck() private view {
        (address hub_, address hook_, address quoter_, address original_) = (hub, hook, quoter, original);
        assembly ("memory-safe") {
            // if (!((msg.sender == hub || msg.sender == hook || msg.sender == quoter || msg.sender == address(0)) && address(this) == original))
            if iszero(
                and(
                    or(eq(caller(), hub_), or(eq(caller(), hook_), or(eq(caller(), quoter_), iszero(caller())))),
                    eq(address(), original_)
                )
            ) {
                mstore(0, 0xd9711eeb) // `GuardedCall()`
                revert(0, 0x04)
            }
        }
    }

    modifier guarded() {
        _guardedCheck();
        _;
    }

    constructor(address hub_, address hook_, address quoter_) {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        original = address(this);

        // Record permitted addresses
        hub = hub_;
        hook = hook_;
        quoter = quoter_;
    }
}
