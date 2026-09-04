// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Burns `feeBps` of every transfer. If the Mill trusted its `assets`
///      argument instead of the balance delta, this token would mint unbacked
///      supply on every wrap.
contract FeeOnTransferERC20 is ERC20 {
    uint16 public immutable feeBps;

    constructor(uint16 feeBps_) ERC20("FoT", "FOT") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0), fee);
    }
}

interface IMillWrap {
    function wrap(uint256 assets, address receiver) external returns (uint256);
}

/// @dev Stands in for the whole class of underlyings that hand control back
///      during a transfer — ERC777 `tokensReceived`, ERC1363, launchpad tokens
///      with a post-transfer notifier. `Mill.wrap` credits the balance delta
///      across `safeTransferFrom`, so without a guard a re-entrant wrap is
///      counted twice: once by the inner call that minted for it, and again by
///      the outer call's delta.
contract ReentrantERC20 is ERC20 {
    address public mill;
    address public beneficiary;
    uint256 public reenterAmount;
    bool private _inside;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// @notice Lets this token spend its own balance on the Mill, so the
    ///         re-entrant wrap has something to deposit.
    function approveMill(address mill_) external {
        _approve(address(this), mill_, type(uint256).max);
    }

    /// @notice Fire exactly one re-entrant wrap of `amount` on the next transfer
    ///         into the Mill.
    function arm(address mill_, address beneficiary_, uint256 amount) external {
        mill = mill_;
        beneficiary = beneficiary_;
        reenterAmount = amount;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (!_inside && mill != address(0) && to == mill && reenterAmount > 0) {
            _inside = true;
            uint256 amt = reenterAmount;
            reenterAmount = 0;
            IMillWrap(mill).wrap(amt, beneficiary);
            _inside = false;
        }
    }
}
